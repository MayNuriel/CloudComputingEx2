import threading
from flask import Flask, request
from datetime import datetime
import boto3
import requests
import time
import os
import uuid
import paramiko

nodeManager = Flask(__name__)
class Manager:
    myIP = None
    siblingIP = None
    tasks = []
    completedTasks = []
    numOfWorkers = 0
    maxNumOfWorkers = 3 # rate limit - total number of new workers
    limit = 3 # rate limit - time in seconds to create new worker
    workerInCreatingProcess = False # indicates whether a worker is still in process of creation
    
    
    @nodeManager.route('/initializationVariables', methods=['POST'])
    def initializationVariables():
        if Manager.myIP is None and Manager.siblingIP is None:
            Manager.myIP = request.args.get('myIP')
            Manager.siblingIP = request.args.get('siblingIP')
            thread = threading.Thread(target=Manager.timer_5_sec_to_increase_workers_if_needed)
            thread.start() 
        return 'POST request processed successfully', 200
   

    @nodeManager.route('/enqueue', methods=['PUT'])
    def enqueue():
       iterations = request.args.get('iterations')
       buffer = request.get_data(as_text=True)  # Extract the body content as string
       Manager.tasks.append((buffer, iterations, datetime.now()))
       return 'POST request processed successfully', 200
    
    @staticmethod
    def timer_5_sec_to_increase_workers_if_needed():
        while True:
            if len(Manager.tasks) > 0 and (datetime.now() - Manager.tasks[0][2]).total_seconds() > Manager.limit:
                if Manager.numOfWorkers < Manager.maxNumOfWorkers:
                    if not Manager.workerInCreatingProcess: 
                        Manager.workerInCreatingProcess = True
                        Manager.numOfWorkers += 1
                        threading.Thread(target=Manager.createWorker).start()
                        Manager.workerInCreatingProcess = False
                else:
                    if Manager.siblingIP is not None and not Manager.workerInCreatingProcess:
                        response = requests.get(f"http://{Manager.siblingIP}:5000/tryGetNodeQuota")
                        if response.status_code == 200 and response.text == "True":
                        # Successful request, so we can create new worker
                            Manager.maxNumOfWorkers += 1
                            Manager.numOfWorkers += 1
                            Manager.workerInCreatingProcess = True
                            threading.Thread(target=Manager.createWorker).start()
                            Manager.workerInCreatingProcess = False
            time.sleep(5)

    @nodeManager.route('/tryGetNodeQuota', methods=['GET'])
    def tryGetNodeQuota():
        if Manager.numOfWorkers < Manager.maxNumOfWorkers:
            Manager.maxNumOfWorkers -= 1
            return "True"
        return "False"

    @nodeManager.route('/pullCompleted', methods=['POST'])
    def pullCompleted():
        top = int(request.args.get('top'))
        completedTasksToReturn = []
        finalResponse = ""
        completedTasksFromSibling = ""
        if top <= 0:
            return []
        elif top <= len(Manager.completedTasks):
            completedTasksToReturn = Manager.completedTasks[:top]
            Manager.completedTasks = Manager.completedTasks[top:] # Updates the queue with the remaining completed tasks
        elif Manager.siblingIP is not None:     # need to get more completed tasks from sibling
            siblingNumOfCompletedTasks = top - len(Manager.completedTasks)
            completedTasksToReturn = Manager.completedTasks
            Manager.completedTasks = []
            response = requests.get(f"http://{Manager.siblingIP}:5000/bringFromSibling?num={siblingNumOfCompletedTasks}") 
            if response.status_code == 200:
                # Successful request
                completedTasksFromSibling = response.json()
                completedTasksToReturn += completedTasksFromSibling
        for task in range(len(completedTasksToReturn)):
            finalResponse += f"\ntask #{task + 1} output is: {completedTasksToReturn[task]}, \n"
        return finalResponse
    
    @nodeManager.route('/bringFromSibling', methods=['GET'])
    def bringFromSibling():
        numOfTasks = int(request.args.get('num'))
        numOfTasks = min(numOfTasks, len(Manager.completedTasks))
        completedTasksToReturn = Manager.completedTasks[:numOfTasks]
        Manager.completedTasks =  Manager.completedTasks[numOfTasks:] #Updates the queue with the remaining completed tasks
        return completedTasksToReturn
    
    @nodeManager.route('/giveWork', methods=['GET'])
    def giveWork():
        if len(Manager.tasks) > 0:
            task = Manager.tasks[0]
            Manager.tasks = Manager.tasks[1:]
            return {"buffer" : task[0], "iterations" : task[1], "status" : 1}
        else:
            return {"status" : 0}
    
    @nodeManager.route('/workDone', methods=['PUT'])
    def workDone():
        response = request.get_json()['response']
        Manager.completedTasks.append(response)
        return "the worker finished working on a task"

    @nodeManager.route('/terminate', methods=['POST'])
    def terminate():
        #terminate worker
        Manager.numOfWorkers -= 1
        workerID = request.get_json()['id']
        region = 'us-east-1'
        ec2 = boto3.client('ec2', region_name=region)
        ec2.terminate_instances(InstanceIds=[workerID])
        return "worker with id: " + workerID + "terminated"

    @staticmethod
    def createWorker():
        # Create a new EC2 instance in a specific region
        region = 'us-east-1'
        ec2_instance = boto3.client('ec2', region_name=region)
        # Generates a random UUID
        end_of_key_name = str(uuid.uuid4())
        # Key pair name
        key_name = 'cloud-course-ex1-' + end_of_key_name
        # Create and get a key pair
        response = ec2_instance.create_key_pair(KeyName=key_name)
        key_material = response['KeyMaterial']
        # Save private key material to a file
        key_file_path = f'{key_name}.pem'
        with open(key_file_path, 'w') as key_file:
            key_file.write(key_material)
        # Secure the key file
        os.chmod(key_file_path, 0o400)

        security_group_name = 'my-sg-ex1-' + end_of_key_name
        # Create security group
        created_security_group = ec2_instance.create_security_group(
            Description='SG to access my instances',
            GroupName=security_group_name,
        )
        security_group_id = created_security_group['GroupId']
        # Allow TCP connection on port 5000
        ec2_instance.authorize_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=[
                {
                    'IpProtocol': 'tcp',
                    'FromPort': 5000,
                    'ToPort': 5000,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0'}]
                },
            ]
        )
        # Allow SSH on port 22
        ec2_instance.authorize_security_group_ingress(
            GroupId=security_group_id,
            IpPermissions=[
                {
                    'IpProtocol': 'tcp',
                    'FromPort': 22,
                    'ToPort': 22,
                    'IpRanges': [{'CidrIp': '0.0.0.0/0'}]
                },
            ]
        )
        # Create a new EC2 instance
        launch = ec2_instance.run_instances(
            ImageId='ami-042e8287309f5df03',
            InstanceType='t3.micro',
            KeyName=key_name,
            SecurityGroupIds=[security_group_id],
            MinCount=1,
            MaxCount=1,
            UserData=f'''#!/bin/bash
                sudo apt-get update
                sudo apt-get install python3
                sudo apt install -y python3-pip
                sudo pip3 install flask
                sudo pip3 install boto3
                sudo pip3 install requests
                ''',
        )
        instance_id = launch['Instances'][0]['InstanceId']
        # Wait for the instance to be ready
        waiter = ec2_instance.get_waiter('instance_status_ok')
        waiter.wait(InstanceIds=[instance_id])
        print(f'Instance {instance_id} is running.')
        # Retrieve information about the EC2 instance
        retrieve = ec2_instance.describe_instances(InstanceIds=[instance_id])
        public_ip = retrieve['Reservations'][0]['Instances'][0]['PublicIpAddress']
        # Transfer the worker.py script to the instance using paramiko
        ssh_client = paramiko.SSHClient()
        ssh_client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        key = paramiko.RSAKey.from_private_key_file(key_file_path)
        ssh_client.connect(hostname=public_ip, username='ubuntu', pkey=key)
        sftp_client = ssh_client.open_sftp()
        sftp_client.put('worker.py', '/home/ubuntu/worker.py')
        sftp_client.close()

        # Execute the worker.py script on the instance using SSH
        ssh_client.exec_command(
            'export FLASK_APP=/home/ubuntu/worker.py && nohup flask run --host 0.0.0.0 &>/dev/null &')

        time.sleep(30) 
        #initializing worker's variables 
        requests.put(f'http://{public_ip}:5000/start?parent_ip={Manager.myIP}&machine2_ip={Manager.siblingIP}&worker_id={instance_id}')
        return f'(public_ip: {public_ip})'

if __name__ == '__main__':
    nodeManager.run(host='0.0.0.0', port=5000)
    

