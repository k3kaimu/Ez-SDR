module msgqueue;

import std.typecons;
import lock_free.rwqueue;

struct MsgQueue(Req, Res)
{
    void pushRequest(Req req) shared
    {
        _reqList.push(req);
    }


    Req popRequest() shared
    {
        return _reqList.pop();
    }


    void pushResponse(Req req, Res res) shared
    {
        auto pair = ReqResPair(req, res);
        _resList.push(pair);
    }


    Tuple!(Req, "req", Res, "res") popResponse() shared
    {
        auto pair = _resList.pop();
        return typeof(return)(pair.req, pair.res);
    }


    bool emptyRequest() shared
    {
        return _reqList.empty;
    }


    bool emptyResponse() shared
    {
        return _resList.empty;
    }


  private:
    RWQueue!(Req) _reqList;
    RWQueue!(ReqResPair) _resList;


    static struct ReqResPair
    {
        Req req;
        Res res;
    }
}
