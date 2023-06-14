from flask import Flask, request
from datetime import datetime
import requests
import time

app = Flask(__name__)

class Worker:
    nodes = []
    instanceId = None
    parentIP = None

    @app.route('/start', methods=['PUT'])
    def start():
        parent = request.args.get('parent_ip')
        machine2 = request.args.get('machine2_ip')
        Worker.instanceId = request.args.get('worker_id')
        Worker.nodes.append(parent)
        Worker.parentIP = parent
        if machine2 is not None:
            Worker.nodes.append(machine2)
        lastWorkTime = datetime.now()
        while (datetime.now() - lastWorkTime).total_seconds() < 60: #rate limit- if 60 sec there is no workthe instance will be terminated
            for node in Worker.nodes:
                task = Worker.giveMeWork(node)
                if task['status'] != 0:
                    result = Worker.work(task['buffer'].encode('utf-8'), int(task['iterations']))
                    Worker.workDone(node, {'response': result.decode('latin-1')})
                    lastWorkTime = datetime.now()
                    continue
            time.sleep(1)
        Worker.terminate()

    @staticmethod
    def work(buffer, iterations):
        import hashlib
        output = hashlib.sha512(buffer).digest()
        for i in range(iterations - 1):
            output = hashlib.sha512(output).digest()
        return output

    # if the request status is 200, we get three fields in the response:
    # status: indicates whether there is a job to do, if status is 0 then no, else yes
    # iterations and buffer, as expected
    @staticmethod
    def giveMeWork(ip):
        url = f"http://{ip}:5000/giveWork"
        try:
            response = requests.get(url)
            if response.status_code == 200:
                return response.json()      
        except Exception as e:
            print(f"Error: {e}")
        return {"status": 0}


    @staticmethod
    def workDone(ip, output):
        url = f"http://{ip}:5000/workDone"
        requests.put(url, json=output)

    @staticmethod
    def terminate():
        url = f"http://{Worker.parentIP}:5000/terminate"
        requests.post(url, json={'id': Worker.instanceId})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
