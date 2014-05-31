event REQ_REPLICA:(seqNum:int, key:int, val:int);
event RESP_REPLICA_COMMIT:int;
event RESP_REPLICA_ABORT:int;
event GLOBAL_ABORT:int;
event GLOBAL_COMMIT:int;
event WRITE_REQ:(client:id, key:int, val:int);
event WRITE_FAIL;
event WRITE_SUCCESS;
event READ_REQ_REPLICA:int;
event READ_REQ:(client:id, key:int);
event READ_FAIL;
event READ_SUCCESS:int;
event REP_READ_FAIL;
event REP_READ_SUCCESS:int;
event Unit;
event Timeout;
event StartTimer:int;
event CancelTimer;
event CancelTimerFailure;
event CancelTimerSuccess;
event MONITOR_WRITE_SUCCESS:(m: id, key:int, val:int);
event MONITOR_WRITE_FAILURE:(m: id, key:int, val:int);
event MONITOR_READ_SUCCESS:(m: id, key:int, val:int);
event MONITOR_READ_FAILURE:id;
event MONITOR_UPDATE:(m:id, key:int, val:int);
event goEnd;
event final;

/*
All the external APIs which are called by the protocol
*/
model machine Timer {
	var target: id;
	start state Init {
		entry {
			target = (id)payload;
			raise(Unit);
		}
		on Unit goto Loop;
	}

	state Loop {
		ignore CancelTimer;
		on StartTimer goto TimerStarted;
	}

	state TimerStarted {
		entry {
			if (*) {
				send(target, Timeout);
				raise(Unit);
			}
		}
		on Unit goto Loop;
		on CancelTimer goto Loop {
			if (*) {
				send(target, CancelTimerFailure);
				send(target, Timeout);
			} else {
				send(target, CancelTimerSuccess);
			}		
		};
	}
}

machine Replica {
	var coordinator: id;
    var data: map[int,int];
	var pendingWriteReq: (seqNum: int, key: int, val: int);
	var shouldCommit: bool;
	var lastSeqNum: int;
	var sendPort:id;
	
	model fun sendToNetwork(target:id, e:eid, p:any) {
		send(sendPort, sendMessage, (target = target, e = e, p = p));
	}
	
	start state bootingState {
		entry {
			coordinator = (id)payload;
		}
		on SenderPort goto Init
		{
			sendPort = (id)payload;
		};
	}
	
    state Init {
	    entry {
			lastSeqNum = 0;
			raise(Unit);
		}
		on Unit goto Loop;
	}

	action HandleReqReplica {
		pendingWriteReq = ((seqNum:int, key:int, val:int))payload;
		assert (pendingWriteReq.seqNum > lastSeqNum);
		shouldCommit = ShouldCommitWrite();
		if (shouldCommit) {
			sendToNetwork(coordinator, RESP_REPLICA_COMMIT, pendingWriteReq.seqNum);
		} else {
			sendToNetwork(coordinator, RESP_REPLICA_ABORT, pendingWriteReq.seqNum);
		}
	}

	action HandleGlobalAbort {
		assert (pendingWriteReq.seqNum >= payload);
		if (pendingWriteReq.seqNum == payload) {
			lastSeqNum = payload;
		}
	}

	action HandleGlobalCommit {
		assert (pendingWriteReq.seqNum >= payload);
		if (pendingWriteReq.seqNum == payload) {
			data.update(pendingWriteReq.key, pendingWriteReq.val);
			//invoke Termination(MONITOR_UPDATE, (m = this, key = pendingWriteReq.key, val = pendingWriteReq.val));
			lastSeqNum = payload;
		}
	}

	action ReadData{
		if(payload in data)
			sendToNetwork(coordinator, REP_READ_SUCCESS, data[payload]);
		else
			sendToNetwork(coordinator, REP_READ_FAIL, null);
	}
	
	state Loop {
		on GLOBAL_ABORT do HandleGlobalAbort;
		on GLOBAL_COMMIT do HandleGlobalCommit;
		on REQ_REPLICA do HandleReqReplica;
		on READ_REQ_REPLICA do ReadData;
	}

	model fun ShouldCommitWrite(): bool 
	{
		return *;
	}
}

machine Coordinator {
	var data: map[int,int];
	var replicas: seq[id];
	var numReplicas: int;
	var i: int;
	var pendingWriteReq: (client: id, key: int, val: int);
	var replica: id;
	var currSeqNum:int;
	var timer: mid;
	var client:id;
	var key: int;
	var readResult: (bool, int);
	var creatorMachine:id;
	var sendPort:id;
	
	model fun sendToNetwork(target:id, e:eid, p:any) {
		send(sendPort, sendMessage, (target = target, e = e, p = p));
	}
	
	start state bootingState {
		entry {
			creatorMachine = ((id, int))payload[0];
			numReplicas = ((id, int))payload[1];
		}
	
		on SenderPort goto Init
		{
			sendPort = (id)payload;
		};
	}
	
	
	state Init {
		entry {
			
			assert (numReplicas > 0);
			i = 0;
			while (i < numReplicas) {
				call(createReplica);
				replicas.insert(i, replica);
				i = i + 1;
			}
			currSeqNum = 0;
			//new Termination(this, replicas);
			timer = new Timer(this);
			raise(Unit);
		}
		on Unit goto Loop;
	}
	
	state createReplica {
		entry {
			sendToNetwork(creatorMachine, createmachine, (creator= this, type = 1, parameter = this));
		}
		on newMachineCreated do PopState;
	}
	
	action PopState {
		replica = (id)payload;
		return;
	}
	state DoRead {
		entry {
			client = payload.client;
			key = payload.key;
			call(PerformRead);
			if(readResult[0])
				raise(READ_FAIL);
			else
				raise(READ_SUCCESS, readResult[1]);
		}
		on READ_FAIL goto Loop
		{
			sendToNetwork(client, READ_FAIL, null);
		};
		on READ_SUCCESS goto Loop
		{	
			sendToNetwork(client, READ_SUCCESS, payload);
		};
	}
	
	model fun ChooseReplica()
	{
			if(*) 
				sendToNetwork(replicas[0], READ_REQ_REPLICA, key);
			else
				sendToNetwork(replicas[sizeof(replicas) - 1], READ_REQ_REPLICA, key);
				
	}
	
	state PerformRead {
		entry{ ChooseReplica(); }
		on REP_READ_FAIL do ReturnResult;
		on REP_READ_SUCCESS do ReturnResult;
		
	}
	
	action ReturnResult {
		if(trigger == REP_READ_FAIL)
			readResult = (true, -1);
		else
			readResult = (false, (int)payload);
		
		return;
	}
	action DoWrite {
		pendingWriteReq = payload;
		currSeqNum = currSeqNum + 1;
		i = 0;
		while (i < sizeof(replicas)) {
			sendToNetwork(replicas[i], REQ_REPLICA, (seqNum=currSeqNum, key=pendingWriteReq.key, val=pendingWriteReq.val));
			i = i + 1;
		}
		send(timer, StartTimer, 100);
		raise(Unit);
	}

	state Loop {
		on WRITE_REQ do DoWrite;
		on Unit goto CountVote;
		on READ_REQ goto DoRead;
		ignore RESP_REPLICA_COMMIT, RESP_REPLICA_ABORT;
	}

	fun DoGlobalAbort() {
		i = 0;
		while (i < sizeof(replicas)) {
			sendToNetwork(replicas[i], GLOBAL_ABORT, currSeqNum);
			i = i + 1;
		}
		sendToNetwork(pendingWriteReq.client, WRITE_FAIL, null);
	}

	state CountVote {
		entry {
			if (i == 0) {
				while (i < sizeof(replicas)) {
					sendToNetwork(replicas[i], GLOBAL_COMMIT, currSeqNum);
					i = i + 1;
				}
				data.update(pendingWriteReq.key, pendingWriteReq.val);
				//invoke Termination(MONITOR_UPDATE, (m = this, key = pendingWriteReq.key, val = pendingWriteReq.val));
				sendToNetwork(pendingWriteReq.client, WRITE_SUCCESS, null);
				send(timer, CancelTimer);
				raise(Unit);
			}
		}
		defer WRITE_REQ, READ_REQ;
		on RESP_REPLICA_COMMIT goto CountVote {
			if (currSeqNum == (int)payload) {
				i = i - 1;
			}
		};
		on RESP_REPLICA_ABORT do HandleAbort;
		on Timeout goto Loop {
			DoGlobalAbort();
		};
		on Unit goto WaitForCancelTimerResponse;
	}

	action HandleAbort {
		if (currSeqNum == (int)payload) {
			DoGlobalAbort();
			send(timer, CancelTimer);
			raise(Unit);
		}
	}

	state WaitForCancelTimerResponse {
		defer WRITE_REQ, READ_REQ;
		ignore RESP_REPLICA_COMMIT, RESP_REPLICA_ABORT;
		on Timeout, CancelTimerSuccess goto Loop;
		on CancelTimerFailure goto WaitForTimeout;
	}

	state WaitForTimeout {
		defer WRITE_REQ, READ_REQ;
		ignore RESP_REPLICA_COMMIT, RESP_REPLICA_ABORT;
		on Timeout goto Loop;
	}
}

machine Client {
    var coordinator: id;
	var mydata : int;
	var counter : int;
    var sendPort:id;
	
	model fun sendToNetwork(target:id, e:eid, p:any) {
		send(sendPort, sendMessage, (target = target, e = e, p = p));
	}
	
	start state bootingState {
		entry {
			coordinator = ((id, int))payload[0];
			mydata = ((id, int))payload[1];
		}
	
		on SenderPort goto Init
		{
			sendPort = (id)payload;
		};
	}
	
	state Init {
	    entry {
	        
			counter = 0;
			new ReadWrite(this);
			raise(Unit);
		}
		on Unit goto DoWrite;
	}
	
	
	state DoWrite {
	    entry {
			mydata = mydata + 1; 
			counter = counter + 1;
			if(counter == 3)
				raise(goEnd);
			sendToNetwork(coordinator, WRITE_REQ, (client=this, key=mydata, val=mydata));
		}
		on WRITE_FAIL goto DoRead
		{
			invoke ReadWrite(MONITOR_WRITE_FAILURE, (m = this, key=mydata, val = mydata))
		};
		on WRITE_SUCCESS goto DoRead
		{
			invoke ReadWrite(MONITOR_WRITE_SUCCESS, (m = this, key=mydata, val = mydata))
		};
		on goEnd goto End;
	}

	state DoRead {
	    entry {
			sendToNetwork(coordinator, READ_REQ, (client=this, key=mydata));
		}
		on READ_FAIL goto DoWrite
		{
			invoke ReadWrite(MONITOR_READ_FAILURE, this);
		};
		on READ_SUCCESS goto DoWrite
		{
			invoke ReadWrite(MONITOR_READ_SUCCESS, (m = this, key = mydata, val = payload));
		};
	}

	state End { }

}

//Monitors


// ReadWrite monitor keeps track of the property that every successful write should be followed by
// successful read and failed write should be followed by a failed read.
// This monitor is created local to each client.

monitor ReadWrite {
	var client : id;
	var data: (key:int,val:int);
	action DoWriteSuccess {
		if(payload.m == client)
			data = (key = payload.key, val = payload.val);
	}
	
	action DoWriteFailure {
		if(payload.m == client)
			data = (key = -1, val = -1);
	}
	action CheckReadSuccess {
		if(payload.m == client)
		{assert(data.key == payload.key && data.val == payload.val);}
			
	}
	action CheckReadFailure {
		if(payload == client)
			assert(data.key == -1 && data.val == -1);
	}
	start state Init {
		entry {
			client = (id) payload;
		}
		on MONITOR_WRITE_SUCCESS do DoWriteSuccess;
		on MONITOR_WRITE_FAILURE do DoWriteFailure;
		on MONITOR_READ_SUCCESS do CheckReadSuccess;
		on MONITOR_READ_FAILURE do CheckReadFailure;
	}
}

//
// The termination monitor checks the eventual consistency property. Eventually logs on all the machines 
// are the same (coordinator, replicas).
//
/*
monitor Termination {
	var coordinator: id;
	var replicas:seq[id];
	var data : map[id, map[int, int]];
	var i :int;
	var j : int;
	var same : bool;
	start state init {
		entry {
			coordinator = ((id, seq[id]))payload[0];
			replicas = ((id, seq[id]))payload[1];
		}
		on MONITOR_UPDATE goto UpdateData;
	}
	
	state UpdateData {
		entry {
		
			data[payload.m].update(payload.key, payload.val);
			if(sizeof(data[coordinator]) == sizeof(data[replicas[0]]))
			{
				i = sizeof(replicas) - 1;
				same = true;
				while(i >= 0)
				{
					if(sizeof(data[replicas[i]]) == sizeof(data[replicas[0]]) && same)
						same = true;
					else
						same = false;
						
					i = i - 1;
				}
			}
			if(same)
			{
				i = sizeof(data[coordinator]) - 1; 
				
				same = true;
				while(i>=0)
				{
					j = sizeof(replicas) - 1;
					while(j>=0)
					{
						assert(keys(data[coordinator])[i] in data[replicas[j]]);
						j = j - 1;
					}
				}
				
				raise(final);
			}
		
		}
		
		on final goto StableState;
		on MONITOR_UPDATE goto UpdateData;
		
	}
	
	stable state StableState{
		entry{}
		on MONITOR_UPDATE goto UpdateData;
	}
	
}
*/

main machine TwoPhaseCommit {
    var coordinator: id;
	var networkedcreatorMachine:id;
	var numberOfClients:int;
	var creatorMachine:id;
	
    start state Init {
	    entry {
			numberOfClients = 2;
			creatorMachine = new MachineCreator();
			networkedcreatorMachine = new NetworkMachine(creatorMachine);
			send(creatorMachine, createmachine, (creator = this, type =0, parameter = (networkedcreatorMachine, 2)));
	    }
		on newMachineCreated goto createClient
		{
			coordinator = (id)payload;
		};
	}
	
	state createClient {
		entry {
			if(numberOfClients == 0)
				raise(delete);
			send(creatorMachine, createmachine, (creator = this, type = 2, parameter = (coordinator, 100*numberOfClients)));
		}
		on newMachineCreated goto createClient
		{
			numberOfClients = numberOfClients - 1;
		};
	}
}