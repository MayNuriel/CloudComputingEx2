# Cloud Computing - Ex2 - Dynamic workload

May Nuriel 318911385 & Omri Shaked 207404484

•	The Task - build a queue & work management system for parallel processing.

•	The system is deployed to AWS by: deploying two "nodeManagers" which are two EC2 instances which offer the needed endpoints:

PUT /enqueue?iterations=num– with the body containing the actual data

POST /pullCompleted?top=num – return the latest completed work items

each one of them creates ec2-instances, "workers", to do the job as needed (with limits which are denoted in the code)



•	The bash script which deploys the code to the cloud is: "setup.sh" 

•	region: us-east-1

•	The "nodeWorker.py" file contains the app "Manager" for the 2 instances which are handling the endpoints. The "worker.py" file contains the app "app" for the worker instances.

•	In addition, you can see an output example of "setup.sh" file in "output.txt".
  the "testing.bin" file is the one we used for the example of testing the enqueue endpoint.
  
•	"FailureModes.txt" is a document detailing failure modes and how to deal with them if this was a real-world project.
  
