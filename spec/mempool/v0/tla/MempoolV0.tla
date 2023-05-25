------------------------------- MODULE MempoolV0 -------------------------------
(******************************************************************************)
(* Mempool V0                                                                 *)
(******************************************************************************)

(* Assumption: The network topology is fixed: nodes do not leave or join the
network, peers do not change. *)

(* One of the goals of this spec is to make their actions and data structures
easily mapped to the code to be able to apply MBT. *)

EXTENDS Base, Integers, Sequences, Maps, TLC, FiniteSets

CONSTANTS 
    \* @type: Int;
    MempoolMaxSize,
    
    \* The configuration of each node
    \* @typeAlias: CONFIG = [keepInvalidTxsInCache: Bool];
    \* @type: NODE_ID -> CONFIG;
    Configs

ASSUME MempoolMaxSize > 0

--------------------------------------------------------------------------------
\* Network state
VARIABLES
    \* @typeAlias: MSG = [sender: NODE_ID, tx: TX];
    \* @type: NODE_ID -> Set(MSG);
    msgs

CONSTANTS
    \* The network topology.
    \* @type: NODE_ID -> Set(NODE_ID);
    Peers

Network == INSTANCE Network 

--------------------------------------------------------------------------------
\* Chain state
VARIABLES
    \* @type: HEIGHT -> Set(TX);
    chain

Chain == INSTANCE Chain

--------------------------------------------------------------------------------
(******************************************************************************)
(* ABCI applications for each node.                                           *)
(******************************************************************************)
VARIABLES 
    \* @type: NODE_ID -> REQUEST -> <<NODE_ID, RESPONSE>>;
    requestResponses

ABCI == INSTANCE ABCIServers

--------------------------------------------------------------------------------

\* @typeAlias: MEMPOOL_TX = [tx: TX, height: HEIGHT, senders: Set(NODE_ID)];
\* @type: Set(MEMPOOL_TX);
MempoolTxs == [
    tx: Txs, 
    height: Heights, 
    senders: SUBSET NodeIds
]

\* Node states
VARIABLES
    \* @type: NODE_ID -> Set(MEMPOOL_TX);
    mempool,
    \* @type: NODE_ID -> Set(TX);
    cache,
    \* @type: NODE_ID -> HEIGHT;
    height

\* To keep track of actions
VARIABLES
    \* @type: [node: NODE_ID, step: Str];
    step,
    \* @type: NODE_ID -> ERROR;
    error

\* vars == <<mempool, cache, height, step, error>>

--------------------------------------------------------------------------------
Steps == {"Init", "CheckTx", "ReceiveCheckTxResponse", 
    "Update", "ReceiveRecheckTxResponse", 
    "P2P_ReceiveTxs", "P2P_SendTx", "ABCI!ProcessCheckTxRequest", 
    "Chain!NewBlock"}

\* @type: Set(ERROR);
Errors == {NoError, "ErrMempoolIsFull", "ErrTxInCache"}

TypeOK == 
    /\ mempool \in [NodeIds -> SUBSET MempoolTxs]
    /\ cache \in [NodeIds -> SUBSET Txs]
    /\ height \in [NodeIds -> Heights]
    /\ step \in [node: NodeIds \cup {NoNode}, name: Steps]
    /\ error \in [NodeIds -> Errors]
    /\ Network!TypeOK
    /\ Chain!TypeOK
    /\ ABCI!TypeOK

\* EmptyMap is not accepted by Apalache's typechecker.
EmptyMapNodeIds == [x \in {} |-> {}]

Init == 
    /\ mempool = [x \in NodeIds |-> {}]
    /\ cache = [x \in NodeIds |-> {}]
    /\ height = [x \in NodeIds |-> 0]
    /\ step = [node |-> NoNode, name |-> "Init"]
    /\ error = [x \in NodeIds |-> NoError]
    /\ Network!Init
    /\ Chain!Init
    /\ ABCI!Init

--------------------------------------------------------------------------------
(******************************************************************************)
(* Auxiliary definitions *)
(******************************************************************************)

setStep(nodeId, s) ==
    step' = [node |-> nodeId, step |-> s]

setError(nodeId, err) ==
    error' = [error EXCEPT ![nodeId] = err]

(******************************************************************************)
(* Mempool *)
(******************************************************************************)

mempoolIsEmpty(nodeId) ==
    mempool[nodeId] = {}

mempoolIsFull(nodeId) ==
    Cardinality(mempool[nodeId]) > MempoolMaxSize

mempoolTxs(nodeId) ==
    { e.tx: e \in mempool[nodeId] }

inMempool(nodeId, tx) ==
    tx \in mempoolTxs(nodeId)

\* CHECK: What if inMempool(nodeId, request.tx) ?
\* @type: (NODE_ID, TX, HEIGHT, NODE_ID) => Bool;
addToMempool(nodeId, tx, h, senderId) ==
    LET newSenders == IF senderId = NoNode THEN {} ELSE {senderId} IN
    LET entry == [tx |-> tx, height |-> h, senders |-> newSenders] IN
    mempool' = [mempool EXCEPT ![nodeId] = @ \cup {entry}]

\* @type: (NODE_ID, Set(TX)) => Bool;
removeFromMempool(nodeId, txs) ==
    mempool' = [mempool EXCEPT ![nodeId] = {e \in @: e.tx \notin txs}]

\* @type: (NODE_ID, TX, NODE_ID) => Bool;
addSender(nodeId, tx, senderId) ==
    LET oldMemTx == CHOOSE e \in mempool[nodeId]: e.tx = tx IN
    LET memTxUpdated == [oldMemTx EXCEPT !.senders = @ \cup {senderId}] IN
    mempool' = [mempool EXCEPT ![nodeId] = (@ \ {oldMemTx}) \cup {memTxUpdated}]

(******************************************************************************)
(* Cache *)
(******************************************************************************)

\* @type: (NODE_ID, TX) => Bool;
inCache(nodeId, tx) ==
    tx \in cache[nodeId]

\* @type: (NODE_ID, TX) => Bool;
addToCache(nodeId, tx) ==
    cache' = [cache EXCEPT ![nodeId] = @ \union {tx}]

\* @type: (NODE_ID, TX) => Bool;
forceRemoveFromCache(nodeId, tx) ==
    cache' = [cache EXCEPT ![nodeId] = @ \ {tx}]

\* @type: (NODE_ID, TX) => Bool;
removeFromCache(nodeId, tx) ==
    IF Configs[nodeId].keepInvalidTxsInCache
    THEN forceRemoveFromCache(nodeId, tx)
    ELSE cache' = cache

--------------------------------------------------------------------------------

(* Validate a transaction received either from a client through an RPC endpoint
or from a peer via P2P. If valid, add it to the mempool. *)
\* [CListMempool.CheckTx]: https://github.com/CometBFT/cometbft/blob/5a8bd742619c08e997e70bc2bbb74650d25a141a/mempool/clist_mempool.go#L202
\* @type: (NODE_ID, TX, NODE_ID) => Bool;
CheckTx(nodeId, tx, senderId) ==
    /\ setStep(nodeId, "CheckTx")
    /\ IF mempoolIsFull(nodeId) THEN
            /\ mempool' = mempool
            /\ cache' = cache
            /\ setError(nodeId, "ErrMempoolIsFull")
            /\ ABCI!Unchanged
        ELSE IF inCache(nodeId, tx) THEN
            \* Record new sender for the tx we've already seen.
            \* Note it's possible a tx is still in the cache but no longer in the mempool
            \* (eg. after committing a block, txs are removed from mempool but not cache),
            \* so we only record the sender for txs still in the mempool.
            /\ IF inMempool(nodeId, tx) /\ senderId # NoNode
                THEN addSender(nodeId, tx, senderId)
                ELSE mempool' = mempool
            /\ cache' = cache
            /\ setError(nodeId, "ErrTxInCache")
            /\ ABCI!Unchanged
        ELSE
            /\ mempool' = mempool
            /\ addToCache(nodeId, tx)
            /\ setError(nodeId, NoError)
            /\ ABCI!SendRequestNewCheckTx(nodeId, tx, senderId)
    /\ UNCHANGED height

\* Receive a specific transaction from a client via RPC. */
\* [Environment.BroadcastTxAsync]: https://github.com/CometBFT/cometbft/blob/111d252d75a4839341ff461d4e0cf152ca2cc13d/rpc/core/mempool.go#L22
CheckTxRPC(nodeId, tx) ==
    /\ setStep(nodeId, "CheckTx")
    /\ CheckTx(nodeId, tx, NoNode)
    /\ Network!Unchanged

\* Callback that handles the response to a CheckTx request to a transaction sent
\* for the first time.
\* Note: tx and sender are arguments to the function resCbFirstTime.
\* [CListMempool.resCbFirstTime]: https://github.com/CometBFT/cometbft/blob/6498d67efdf0a539e3ca0dc3e4a5d7cb79878bb2/mempool/clist_mempool.go#L369
\* @type: (NODE_ID) => Bool;
ReceiveCheckTxResponse(nodeId) ==
    /\ setStep(nodeId, "ReceiveCheckTxResponse")
    /\ \E request \in ABCI!CheckRequests(nodeId):
        LET response == ABCI!ResponseFor(nodeId, request) IN
        LET senderId == ABCI!SenderFor(nodeId, request) IN
        /\ IF response.error = NoError THEN
                IF mempoolIsFull(nodeId) THEN
                    /\ mempool' = mempool
                    /\ forceRemoveFromCache(nodeId, request.tx)
                    /\ setError(nodeId, "ErrMempoolIsFull")
                ELSE
                    \* inMempool(nodeId, request.tx) should be false
                    /\ addToMempool(nodeId, request.tx, height[nodeId], senderId)
                    /\ cache' = cache
                    /\ setError(nodeId, NoError)
           ELSE \* ignore invalid transaction
                /\ mempool' = mempool
                /\ removeFromCache(nodeId, request.tx)
                /\ setError(nodeId, NoError)
        /\ ABCI!RemoveRequest(nodeId, request)
    /\ UNCHANGED <<height>>
    /\ Network!Unchanged

\* Callback that handles the response to a CheckTx request to a transaction sent
\* after the first time (on Update).
\* [CListMempool.resCbRecheck]: https://github.com/CometBFT/cometbft/blob/5a8bd742619c08e997e70bc2bbb74650d25a141a/mempool/clist_mempool.go#L432
\* @type: (NODE_ID) => Bool;
ReceiveRecheckTxResponse(nodeId) == 
    /\ setStep(nodeId, "ReceiveRecheckTxResponse")
    /\ \E request \in ABCI!RecheckRequests(nodeId):
        LET response == ABCI!ResponseFor(nodeId, request) IN
        /\ inMempool(nodeId, request.tx)
        /\ IF response.error = NoError THEN
                \* Tx became invalidated due to newly committed block.
                /\ removeFromMempool(nodeId, {request.tx})
                /\ removeFromCache(nodeId, request.tx)
           ELSE /\ mempool' = mempool
                /\ cache' = cache
        /\ ABCI!RemoveRequest(nodeId, request)
    /\ UNCHANGED <<error, height>>
    /\ Network!Unchanged

(* The consensus reactors first reaps a list of transactions from the mempool,
executes the transactions in the app, adds them to a newly block, and finally
updates the mempool. The list of transactions is taken in FIFO order but we
don't care about the order in this spec. Then we model the mempool txs as a set
instead of a sequence of transactions. *)
(* BlockExecutor calls Update to update the mempool after executing txs.
txResults are the results of ResponseFinalizeBlock for every tx in txs.
BlockExecutor holds the mempool lock while calling this function. *)
\* [CListMempool.Update] https://github.com/CometBFT/cometbft/blob/6498d67efdf0a539e3ca0dc3e4a5d7cb79878bb2/mempool/clist_mempool.go#L577
\* @type: (NODE_ID, HEIGHT, Set(TX), (TX -> Bool)) => Bool;
Update(nodeId, h, txs, txValidResults) ==
    /\ setStep(nodeId, "Update")
    /\ txs # {}
    
    /\ height' = [height EXCEPT ![nodeId] = h]
    
    \* Remove all txs from the mempool.
    /\ removeFromMempool(nodeId, txs)
    
    \* update cache for all transactions
    \* Add valid committed txs to the cache (in case they are missing).
    \* And remove invalid txs, if keepInvalidTxsInCache is false.
    /\ LET 
            validTxs == {tx \in txs: txValidResults[tx]}
            invalidTxs == {tx \in txs: ~ txValidResults[tx] /\ ~ Configs[nodeId].keepInvalidTxsInCache} 
       IN
       cache' = [cache EXCEPT ![nodeId] = (@ \union validTxs) \ invalidTxs]

    \* Either recheck non-committed txs to see if they became invalid
    \* or just notify there're some txs left.
    /\ IF mempoolIsEmpty(nodeId) THEN
            ABCI!Unchanged
       ELSE 
            \* NOTE: globalCb may be called concurrently.
            ABCI!SendRequestRecheckTxs(nodeId, txs)

    /\ UNCHANGED <<error>>
    /\ Network!Unchanged

(* Receive a transaction from a peer and validate it with CheckTx. *)
\* [Reactor.Receive]: https://github.com/CometBFT/cometbft/blob/111d252d75a4839341ff461d4e0cf152ca2cc13d/mempool/reactor.go#L93
P2P_ReceiveTxs(nodeId) == 
    /\ setStep(nodeId, "P2P_ReceiveTxs")
    /\ \E msg \in Network!IncomingMsgs(nodeId):
        /\ CheckTx(nodeId, msg.tx, msg.sender)
        /\ Network!Receive(nodeId, msg)

(* The mempool reactor loops through its mempool and sends transactions one by
one to each of its peers. *)
\* [Reactor.broadcastTxRoutine] https://github.com/CometBFT/cometbft/blob/5049f2cc6cf519554d6cd90bcca0abe39ce4c9df/mempool/reactor.go#L132
P2P_SendTx(nodeId) ==
    /\ setStep(nodeId, "P2P_SendTx")
    /\ \E peer \in Peers[nodeId], tx \in mempoolTxs(nodeId):
        LET msg == [sender |-> nodeId, tx |-> tx] IN
        \* If the msg was not already sent to this peer.
        /\ ~ Network!ReceivedMsg(peer, msg)
        \* If the peer is not a tx's sender.
        /\ peer \notin { e.tx : e \in {e \in mempool[nodeId]: e.tx = tx} }
        /\ Network!SendTo(msg, peer)
        /\ UNCHANGED <<mempool, cache, error, height>>
        /\ ABCI!Unchanged

--------------------------------------------------------------------------------
NodeNext == 
    \E nodeId \in NodeIds:
        \* Receive some transaction from a client via RPC
        \/ \E tx \in Txs: CheckTxRPC(nodeId, tx)

        \* Receive a (New) CheckTx response from the application
        \/ ReceiveCheckTxResponse(nodeId)

        \* Consensus reactor creates a block and updates the mempool
        \/  /\ ~ Chain!IsEmpty
            /\ height[nodeId] <= Chain!LatestHeight
            /\ LET txs == Chain!GetBlock(height[nodeId]) IN
                \E txValidResults \in [txs -> BOOLEAN]:
                    Update(nodeId, height[nodeId], txs, txValidResults)

        \* Receive a (Recheck) CheckTx response from the application
        \/ ReceiveRecheckTxResponse(nodeId)

        \* Receive a transaction from a peer
        \/ P2P_ReceiveTxs(nodeId)

        \* Send a transaction in the mempool to a peer
        \/ P2P_SendTx(nodeId)

        \* The ABCI application process a request and generates a response
        \/  /\ ABCI!ProcessCheckTxRequest(nodeId)
            /\ setStep(nodeId, "ABCI!ProcessCheckTxRequest")
            /\ UNCHANGED <<mempool, cache, height, error>>
            /\ Network!Unchanged

Next ==
    \/  /\ NodeNext
        /\ Chain!Unchanged

    \* Some node, not necessarily in NodeIds, adds a new block to the chain.
    \* The transactions for the new block are not already in the chain, and they 
    \* are all valid.
    \/ \E txs \in SUBSET (Txs \ Chain!AllTxsInChain) \ {{}}:
        /\ \A tx \in txs: isValid(tx)
        /\ Chain!NewBlockFrom(txs)
        /\ setStep(NoNode, "Chain!NewBlock")
        /\ UNCHANGED <<mempool, cache, height, error>>
        /\ Network!Unchanged
        /\ ABCI!Unchanged

--------------------------------------------------------------------------------
(******************************************************************************)
(* Test scenarios *)
(******************************************************************************)

EmptyCache == 
    \E nodeId \in NodeIds:
        /\ ~ mempoolIsEmpty(nodeId)
        /\ cache[nodeId] = {}
NotEmptyCache == ~ EmptyCache

NonEmptyCache == 
    \E nodeId \in NodeIds:
        /\ ~ mempoolIsEmpty(nodeId)
        /\ cache[nodeId] # {}
NotNonEmptyCache == ~ NonEmptyCache

ReceiveRecheckTxResponseTest ==
    \E nodeId \in NodeIds: step.nodeId = "ReceiveRecheckTxResponse"
NotReceiveRecheckTxResponse == ~ ReceiveRecheckTxResponseTest

P2PReceiveTxsTest ==
    \E nodeId \in NodeIds: step.nodeId = "P2P_ReceiveTxs"
NotP2PReceiveTxs == ~ P2PReceiveTxsTest

SendTxTest ==
    \E nodeId \in NodeIds: step.nodeId = "SendTx"
NotSendTx == ~ SendTxTest

\* @typeAlias: STATE = [msgs: NODE_ID -> Set(MSG), chain: HEIGHT -> Set(TX), requestResponses: NODE_ID -> REQUEST -> <<NODE_ID, RESPONSE>>, mempool: NODE_ID -> Set(MEMPOOL_TX), cache: NODE_ID -> Set(TX), height: NODE_ID -> HEIGHT, step: NODE_ID -> Str, error: NODE_ID -> ERROR];
\* @type: Seq(STATE) => Bool;
SendThenCheck(trace) ==
    \E i, j \in DOMAIN trace: i < j /\
        \E n \in NodeIds:
            LET state1 == trace[i] IN 
            LET state2 == trace[j] IN
            /\ state1.step[n] = "SendTx"
            /\ state2.step[n] = "CheckTx" 
            \* /\ Len(trace) = 10

\* @type: Seq(STATE) => Bool;
NotSendThenCheck(trace) == ~ SendThenCheck(trace)

\* @type: Seq(STATE) => Bool;
RemoveFromCacheThenAddAgain(trace) ==
    \E i, j \in DOMAIN trace: i < j /\
        \E n \in NodeIds:
            LET state1 == trace[i] IN 
            LET state2 == trace[j] IN
            /\ state1.step[n] = "Update"
            /\ state1.cache[n] = {}
            /\ state2.cache[n] # {}

\* @type: Seq(STATE) => Bool;
NotRemoveFromCacheThenAddAgain(trace) == ~ RemoveFromCacheThenAddAgain(trace)

================================================================================
Created by Hernán Vanzetto on 1 May 2023