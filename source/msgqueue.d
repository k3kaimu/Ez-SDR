module msgqueue;

import core.time;

import std.typecons;
import lock_free.rwqueue;
import std.experimental.allocator.mallocator;
import std.experimental.allocator;
import automem.vector;



/** 単一スレッドからの書き込みと，単一スレッドからの読み込みを許す通知付きオブジェクト．
一度書き込みをすると，それ以降は読み取り専用となる．
*/
struct NotifiedLazy(T)
{
    import core.atomic;
    import core.sync.event;
    import std.experimental.allocator;


    static
    shared(NotifiedLazy)* make(Alloc)(ref Alloc alloc)
    {
        auto ptr = alloc.make!(NotifiedLazy)();
        ptr.initialize();
        return cast(shared)ptr;
    }


    static
    shared(NotifiedLazy)* make()
    {
        import std.experimental.allocator.mallocator;
        return NotifiedLazy.make!(shared(Mallocator))(Mallocator.instance);
    }


    static
    void dispose(Alloc)(NotifiedLazy* ptr, ref Alloc alloc)
    {
        ptr.terminate();
        alloc.dispose(ptr);
    }


    static
    void dispose(NotifiedLazy* ptr)
    {
        import std.experimental.allocator.mallocator;
        NotifiedLazy.dispose!(shared(Mallocator))(ptr, Mallocator.instance);
    }


    ~this()
    {
        this.terminate();
    }


    @disable this(this);
    @disable void opAssign(NotifiedLazy);


    void initialize()
    {
        _isNull = true;
        _nofity.initialize(true, false);
    }


    void terminate()
    {
        _nofity.terminate();
    }


    void write(T value) shared
    {
        // 一度書き込みをすると，それ以降は書き込めない
        if(!cas(&_isNull, true, false)) return;

        // ここ以降は必ず単一スレッドのみが実行できる
        _response = value;
        (cast()_nofity).setIfInitialized();
    }


    ref shared(T) read() shared
    {
        // 書き込みされるまで読み込めない
        (cast()_nofity).wait();
        assert(!_isNull);
        return _response;
    }


    bool tryRead(ref T lhs, Duration timeout = 0.usecs) shared
    {
        if(_isNull) return false;
        immutable bool check = (cast()_nofity).wait(timeout);
        if(check) {
            assert(!_isNull);
            lhs = _response;
        }
        return check;
    }


    bool tryRead(scope void delegate(shared(T)) dg, Duration timeout = 0.usecs) shared
    {
        if(_isNull) return false;
        immutable bool check = (cast()_nofity).wait(timeout);
        if(check) {
            assert(!_isNull);
            dg(_response);
            assert(!_isNull);
        }
        return check;
    }


  private:
    T _response;
    Event _nofity;
    bool _isNull;
}

unittest
{
    shared msg = NotifiedLazy!int.make();
    scope(exit) NotifiedLazy!int.dispose(cast(NotifiedLazy!int*)msg);

    assert(msg._isNull == true);

    msg.write(1);
    assert(msg._response == 1);
    assert(msg._isNull == false);
    msg.write(2);
    assert(msg._response == 1);
    assert(msg._isNull == false);
    assert(msg.read == 1);
}

unittest
{
    import core.thread;

    shared msg1 = NotifiedLazy!int.make(),
           msg2 = NotifiedLazy!int.make();
    scope(exit) {
        NotifiedLazy!int.dispose(cast(NotifiedLazy!int*)msg1);
        NotifiedLazy!int.dispose(cast(NotifiedLazy!int*)msg2);
    }

    int dst;
    assert(!msg1.tryRead(dst));
    assert(!msg1.tryRead((_){}));

    auto thread = new Thread((){
        assert(msg2.read == 2);
        assert(msg1.read == 1);
    }).start();
    scope(exit) thread.join();

    msg1.write(1);
    msg2.write(2);

    assert(msg1.tryRead(dst));
    assert(dst == 1);

    bool exec = false;
    assert(msg1.tryRead((x){ assert(x == 1); exec = true; }));
    assert(exec);
}


struct TaskEntry
{
    void* ptr;
    bool function(void*) ready;
    void function(void*) func;
    void function(void*) finish;

    bool isReady() { return this.ready(this.ptr); }
    void run() { this.func(ptr); }
    void terminate() { this.finish(this.ptr); }
}


TaskEntry makeTaskEntry(Value, Pred, Callable)(Value v, Pred ready, Callable fn)
if(is(typeof(Pred.init(lvalueOf!Value)) : bool) && is(typeof(Callable.init(lvalueOf!Value))))
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;
    alias alloc = Mallocator.instance;

    static struct Payload
    {
        Value v;
        Pred ready;
        Callable fn;
    }


    Payload* ptr = alloc.make!Payload();
    ptr.v = v;
    ptr.ready = ready;
    ptr.fn = fn;


    static bool isReady(void* ptr)
    {
        auto payload = cast(Payload*)ptr;
        return payload.ready(payload.v);
    }


    static void task(void* ptr)
    {
        auto payload = cast(Payload*)ptr;
        return payload.fn(payload.v);
    }


    static void finish(void* ptr)
    {
        auto payload = cast(Payload*)ptr;
        alloc.dispose(payload);
    }


    return Entry(ptr, &isReady, &task);
}


unittest
{
    
}


final class RequestQueue(Req, Flag!"assumeUnique" assumeUnique = No.assumeUnique,  Allocator = Mallocator)
{
    import core.lifetime : move;

    static if(assumeUnique)
    {
        private {
            alias IOReq = Req;
        }
    }
    else
    {
        private {
            alias IOReq = shared(Req);
        }
    }

    static if(!is(typeof(Allocator.instance)))
    {
        this(Allocator alloc)
        {
            _alloc = alloc;
        }


        ref Allocator allocator() {
            return _alloc;
        }


        private Allocator _alloc;
    }
    else
    {
        static ref auto allocator() {
            return Allocator.instance;
        }
    }


    void pushRequest()(auto ref IOReq req) shared
    {
        IOReq* p = this.allocator.make!(IOReq)();
        move(req, *p);
        _reqList.push(cast(shared) p);
    }


    IOReq popRequest() shared
    {
        IOReq* p = cast(IOReq*)_reqList.pop();
        scope(exit) this.allocator.dispose(p);
        return move(*p);
    }


    bool emptyRequest() shared
    {
        return _reqList.empty;
    }


    Commander makeCommander() shared
    {
        return new Commander(this);
    }


    Executer makeExecuter() shared
    {
        return new Executer(this);
    }


    static final class Commander
    {
        this(shared RequestQueue queue)
        {
            _queue = queue;
        }


        void push(Req req)
        {
            _queue.pushRequest(req);
        }


        shared RequestQueue _queue;
    }


    static final class Executer
    {
        this(shared RequestQueue queue)
        {
            _queue = queue;
        }


        IOReq[] allRequestList()
        {
            return _reqList[];
        }


        void peekAllRequest()
        {
            while(! _queue.emptyRequest)
                _reqList ~= _queue.popRequest();
        }


        bool empty()
        {
            this.peekAllRequest();
            return _reqList.empty;
        }


        IOReq front()
        {
            this.peekAllRequest();
            return _reqList[0];
        }


        void popFront()
        {
            this.peekAllRequest();
            _reqList.popFront();
        }


      private:
        shared RequestQueue _queue;
        Vector!(IOReq, Allocator) _reqList;
    }



  private:
    RWQueue!(Req*) _reqList;
}


alias UniqueRequestQueue(Req, Allocator = Mallocator) = RequestQueue!(Req, Yes.assumeUnique, Allocator);



/**
Move Semantics Message Queue
*/
final class MsgQueue(Req, Res, Flag!"assumeUnique" assumeUnique = No.assumeUnique, Allocator = Mallocator)
{
    import core.lifetime : move;

    static if(assumeUnique)
    {
        private {
            alias IOReq = Req;
            alias IORes = Res;
            alias IOReqResPair = ReqResPair;
        }
    }
    else
    {
        private {
            alias IOReq = shared(Req);
            alias IORes = shared(Res);
            alias IOReqResPair = shared(ReqResPair);
        }
    }

    static if(!is(typeof(Allocator.instance)))
    {
        this(Allocator alloc)
        {
            _alloc = alloc;
        }


        ref Allocator allocator() {
            return _alloc;
        }


        private Allocator _alloc;
    }
    else
    {
        static ref auto allocator() {
            return Allocator.instance;
        }
    }


    void pushRequest()(auto ref IOReq req) shared
    {
        IOReq* p = this.allocator.make!(IOReq)();
        move(req, *p);
        _reqList.push(cast(shared) p);
    }


    IOReq popRequest() shared
    {
        IOReq* p = cast(IOReq*)_reqList.pop();
        scope(exit) this.allocator.dispose(p);
        return move(*p);
    }


    void pushResponse()(auto ref IOReq req, auto ref IORes res) shared
    {
        IOReqResPair* p = this.allocator.make!(IOReqResPair)(move(req), move(res));
        _resList.push(cast(shared) p);
    }


    IOReqResTuple popResponse() shared
    {
        IOReqResPair* p = cast(IOReqResPair*)_resList.pop();
        scope(exit) this.allocator.dispose(p);
        return IOReqResTuple(move(p.req), move(p.res));
    }


    bool emptyRequest() shared
    {
        return _reqList.empty;
    }


    bool emptyResponse() shared
    {
        return _resList.empty;
    }

  static if(assumeUnique)
  {
    Commander makeCommander() shared
    {
        return new Commander(this);
    }


    Executer makeExecuter() shared
    {
        return new Executer(this);
    }


    static final class Commander
    {
        this(shared MsgQueue queue)
        {
            _queue = queue;
        }


        IOReqResTuple[] allResponseList()
        {
            return _resList[];
        }


        void peekAllResponse()
        {
            while(! _queue.emptyResponse)
                _resList ~= _queue.popResponse();
        }


        bool emptyResponse()
        {
            this.peekAllResponse();
            return _resList.empty;
        }


        IOReqResTuple popResponse()
        {
            this.peekAllResponse();
            auto f = _resList[0];
            _resList.popFront();
            return f;
        }


        void pushRequest(Req req)
        {
            _queue.pushRequest(req);
        }


        shared MsgQueue _queue;
        Vector!(IOReqResTuple, Allocator) _resList;
    }


    static final class Executer
    {
        this(shared MsgQueue queue)
        {
            _queue = queue;
        }


        IOReq[] allRequestList()
        {
            return _reqList[];
        }


        void peekAllRequest()
        {
            while(! _queue.emptyRequest)
                _reqList ~= _queue.popRequest();
        }


        bool emptyRequest()
        {
            this.peekAllRequest();
            return _reqList.empty;
        }


        Req popRequest()
        {
            this.peekAllRequest();
            auto f = _reqList[0];
            _reqList.popFront();
            return f;
        }


        void pushResponse(Req req, Res res)
        {
            _queue.pushResponse(req, res);
        }


      private:
        shared MsgQueue _queue;
        Vector!(IOReq, Allocator) _reqList;
    }
  }


  private:
    RWQueue!(Req*) _reqList;
    RWQueue!(ReqResPair*) _resList;


    static struct ReqResPair
    {
        Req req;
        Res res;
    }


    alias IOReqResTuple = Tuple!(IOReq, "req", IORes, "res");
}


/**
Move Semantics Message Queue with Unique Request and Unique Response
*/
alias UniqueMsgQueue(Req, Res, Allocator = Mallocator) = MsgQueue!(Req, Res, Yes.assumeUnique, Allocator);

// unittest
// {
//     static struct S {
//         int a;
//         @disable this(this);        // non-copyable
//     }
//     static struct U {
//         int[] a;
//         @disable this(this);        // non-copyable
//     }

//     UniqueMsgQueue!(S, U) q;
// }



