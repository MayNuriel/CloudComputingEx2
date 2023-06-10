KEY_NAME="cloud-course-`date +'%N'`"
KEY_PEM="$KEY_NAME.pem"

echo "Creating key pair $KEY_PEM to connect to instances and save locally"
KEY_PAIR=$(aws ec2 create-key-pair --key-name $KEY_NAME)
echo $KEY_PAIR | grep -o "\"KeyMaterial\": \".*\"" | cut -d "\"" -f 4 | sed 's/\\n/\n/g' > $KEY_PEM

# Secure the key pair
chmod 400 $KEY_PEM

SEC_GRP="my-sg-`date +'%N'`"

echo "Setting up firewall $SEC_GRP"
aws ec2 create-security-group   \
    --group-name $SEC_GRP       \
    --description "Access my instances" 

# Figure out my IP
MY_IP=$(curl ipinfo.io/ip)
echo "My IP: $MY_IP"


echo "Setting up rule allowing SSH access to $MY_IP only"
aws ec2 authorize-security-group-ingress --group-name $SEC_GRP --port 22 --protocol tcp --cidr 0.0.0.0/0

echo "Setting up rule allowing HTTP (port 5000) access to all IPs"
aws ec2 authorize-security-group-ingress        \
    --group-name $SEC_GRP --port 5000 --protocol tcp \
    --cidr 0.0.0.0/0

UBUNTU_20_04_AMI="ami-042e8287309f5df03"

echo "Creating first Ubuntu 20.04 instance..."
RUN_INSTANCES_1=$(aws ec2 run-instances   \
    --image-id $UBUNTU_20_04_AMI        \
    --instance-type t3.micro            \
    --key-name $KEY_NAME                \
    --security-groups $SEC_GRP)

INSTANCE_ID_1=$(echo $RUN_INSTANCES_1 | grep -o "\"InstanceId\": \".*\"" | cut -d "\"" -f 4)

echo "Waiting for first instance creation..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID_1

PUBLIC_IP_OF_MY_INSTANCE_1=$(aws ec2 describe-instances  --instance-ids $INSTANCE_ID_1 | 
    grep -o "\"PublicIpAddress\": \".*\"" | cut -d "\"" -f 4
)

echo "New instance $INSTANCE_ID_1 @ $PUBLIC_IP_OF_MY_INSTANCE_1"

echo "Creating second Ubuntu 20.04 instance..."
RUN_INSTANCES_2=$(aws ec2 run-instances   \
    --image-id $UBUNTU_20_04_AMI        \
    --instance-type t3.micro            \
    --key-name $KEY_NAME                \
    --security-groups $SEC_GRP)

INSTANCE_ID_2=$(echo $RUN_INSTANCES_2 | grep -o "\"InstanceId\": \".*\"" | cut -d "\"" -f 4)

echo "Waiting for second instance creation..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID_2

PUBLIC_IP_OF_MY_INSTANCE_2=$(aws ec2 describe-instances  --instance-ids $INSTANCE_ID_2 | 
    grep -o "\"PublicIpAddress\": \".*\"" | cut -d "\"" -f 4
)

echo "New instance $INSTANCE_ID_2 @ $PUBLIC_IP_OF_MY_INSTANCE_2"

echo "Deploying code to production instances"
scp -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=60" nodeManager.py ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_1:/home/ubuntu/
scp -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=60" worker.py ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_1:/home/ubuntu/
scp -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=60" nodeManager.py ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_2:/home/ubuntu/
scp -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=60" worker.py ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_2:/home/ubuntu/

echo "Setting up production environment on first instance"
ssh -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=10" ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_1 <<EOF
    echo "export myIP=$PUBLIC_IP_OF_MY_INSTANCE_1" >> ~/.bashrc
    echo "export siblingIP=$PUBLIC_IP_OF_MY_INSTANCE_2" >> ~/.bashrc
    source ~/.bashrc
    exit
EOF

echo "Setting up production environment on second instance"
ssh -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=10" ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_2 <<EOF
    echo "export myIP=$PUBLIC_IP_OF_MY_INSTANCE_2" >> ~/.bashrc
    echo "export siblingIP=$PUBLIC_IP_OF_MY_INSTANCE_1" >> ~/.bashrc
    source ~/.bashrc
    exit
EOF

echo "setup production environment of the first instance"
ssh -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=10" ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_1 <<EOF
    sudo apt-get update
    sudo apt-get install python3
    sudo apt install -y python3-pip
    sudo pip3 install flask
    sudo pip3 install boto3
    sudo pip3 install requests
    sudo apt-get install -y python3-paramiko
    # run app
    export FLASK_APP=nodeManager.py
    nohup flask run --host 0.0.0.0  &>/dev/null &
    exit
EOF

echo "setup production environment of the second instance"
ssh -i $KEY_PEM -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=10" ubuntu@$PUBLIC_IP_OF_MY_INSTANCE_2 <<EOF
    sudo apt-get update
    sudo apt-get install python3
    sudo apt install -y python3-pip
    sudo pip3 install flask
    sudo pip3 install boto3
    sudo pip3 install requests
    sudo apt-get install -y python3-paramiko
    # run app
    export FLASK_APP=nodeManager.py
    nohup flask run --host 0.0.0.0  &>/dev/null &
    exit
EOF

IAM_ROLE_NAME1="name-1-cloud-course-`date +'%N'`"
IAM_ROLE_NAME2="name-2-cloud-course-`date +'%N'`"
sleep 1

# Create the IAM role
IAM_ROLE_ARN1=$(aws iam create-role --role-name "$IAM_ROLE_NAME1" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' --query 'Role.Arn' --output text)
sleep 1
IAM_ROLE_ARN2=$(aws iam create-role --role-name "$IAM_ROLE_NAME2" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' --query 'Role.Arn' --output text)
sleep 1

IAM_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:CreateKeyPair",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:GetWaiter"
      ],
      "Resource": "*"
    }
  ]
}'
sleep 1

# Create the IAM policy
IAM_POLICY_ARN1=$(aws iam create-policy --policy-name "${IAM_ROLE_NAME1}-policy" --policy-document "$IAM_POLICY" --query 'Policy.Arn' --output text)
sleep 1
IAM_POLICY_ARN2=$(aws iam create-policy --policy-name "${IAM_ROLE_NAME2}-policy" --policy-document "$IAM_POLICY" --query 'Policy.Arn' --output text)
sleep 1
# Attach the IAM policy to the IAM role
aws iam attach-role-policy --role-name "$IAM_ROLE_NAME1" --policy-arn "$IAM_POLICY_ARN1"
sleep 1
aws iam attach-role-policy --role-name "$IAM_ROLE_NAME2" --policy-arn "$IAM_POLICY_ARN2"
sleep 1
# Create the IAM instance profile
sleep 1
aws iam create-instance-profile --instance-profile-name "$IAM_ROLE_NAME1"
sleep 1
aws iam create-instance-profile --instance-profile-name "$IAM_ROLE_NAME2"
sleep 1
# Add the IAM role to the instance profile
aws iam add-role-to-instance-profile --instance-profile-name "$IAM_ROLE_NAME1" --role-name "$IAM_ROLE_NAME1"
sleep 1
aws iam add-role-to-instance-profile --instance-profile-name "$IAM_ROLE_NAME2" --role-name "$IAM_ROLE_NAME2"
sleep 1

# Associate the IAM instance profile with the EC2 instances
aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID_1" --iam-instance-profile Name="$IAM_ROLE_NAME1"
sleep 1
aws ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID_2" --iam-instance-profile Name="$IAM_ROLE_NAME2"
sleep 1

# Verify the IAM role and instance profile associations
aws ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$INSTANCE_ID_1"
sleep 1
aws ec2 describe-iam-instance-profile-associations --filters "Name=instance-id,Values=$INSTANCE_ID_2"
sleep 1

echo "IAM roles '$IAM_ROLE_NAME1' and '$IAM_ROLE_NAME2' have been created and attached to the EC2 instances."

#Initializing the two instances:
curl -s -X POST "http://$PUBLIC_IP_OF_MY_INSTANCE_1:5000/initializationVariables?myIP=$PUBLIC_IP_OF_MY_INSTANCE_1&siblingIP=$PUBLIC_IP_OF_MY_INSTANCE_2" &
curl -s -X POST "http://$PUBLIC_IP_OF_MY_INSTANCE_2:5000/initializationVariables?myIP=$PUBLIC_IP_OF_MY_INSTANCE_2&siblingIP=$PUBLIC_IP_OF_MY_INSTANCE_1" &

echo "---------------------------------------------------------------------------"
echo "testing endpoints"
echo -e "enqueue work to the first instance by the command: curl -X PUT --data-binary \"@testing.bin\" \"http://$PUBLIC_IP_OF_MY_INSTANCE_1:5000/enqueue?iterations=1\""
echo ""
curl -X PUT --data-binary "@testing.bin" "http://$PUBLIC_IP_OF_MY_INSTANCE_1:5000/enqueue?iterations=1"
echo ""
echo -e "enqueue work to the first instance by the command: curl -X PUT --data-binary \"@testing.bin\" \"http://$PUBLIC_IP_OF_MY_INSTANCE_2:5000/enqueue?iterations=2\""
echo ""
curl -X PUT --data-binary "@testing.bin" "http://$PUBLIC_IP_OF_MY_INSTANCE_2:5000/enqueue?iterations=2"
echo ""
echo "Waiting for 10 minutes...until the instances will be deployed.."
sleep 600
echo ""
echo -e "pull completed the 2 tasks from the first instance by the command: curl -X POST \"http://$PUBLIC_IP_OF_MY_INSTANCE_1:5000/pullCompleted?top=2\""
echo ""
curl -X POST "http://$PUBLIC_IP_OF_MY_INSTANCE_1:5000/pullCompleted?top=2"
echo ""
