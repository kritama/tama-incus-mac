"""Opt-in idle-stream regression against an already ready isolated runtime."""
import argparse
import http.client
import json
from pathlib import Path
import socket
import statistics
import time
from datetime import datetime, timezone
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--state-dir',type=Path,required=True)
parser.add_argument('--report',type=Path,required=True)
args=parser.parse_args()
state=args.state_dir.resolve()
peers=[]
def get(endpoint,path):
    connection=http.client.HTTPConnection('localhost',timeout=3)
    connection.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
    connection.sock.settimeout(3)
    connection.sock.connect(str(state/endpoint))
    try:
        began=time.monotonic()
        connection.request('GET',path)
        response=connection.getresponse()
        result=json.loads(response.read())
        assert response.status==200,(path,response.status,result)
        return result,time.monotonic()-began
    finally:
        connection.close()
try:
    for _ in range(80):
        peer=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        peer.settimeout(3)
        peer.connect(str(state/'incus.sock'))
        peer.sendall(b'GET /1.0 HTTP/1.1\r\nHost: localhost\r\n')
        peers.append(peer)
    time.sleep(1)
    samples=[]
    for _ in range(20):
        status,elapsed=get('runtime.sock','/v1/runtime/status')
        assert status['state']=='ready',status
        samples.append(elapsed)
        health,elapsed=get('runtime.sock','/v1/runtime/health')
        assert health['protocol_version']==1,health
        samples.append(elapsed)
        _,elapsed=get('incus.sock','/1.0')
        samples.append(elapsed)
    report={'status':'passed','tested_at':datetime.now(timezone.utc).isoformat(),
            'idle_incus_streams':len(peers),'successful_control_health_and_incus_requests':len(samples),
            'maximum_response_seconds':max(samples),'median_response_seconds':statistics.median(samples)}
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
finally:
    for peer in peers:
        peer.close()
