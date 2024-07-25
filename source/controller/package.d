module controller;

import std.complex;
import std.socket;
import std.json;

import device;


interface IController
{
    void setup(IDevice[], JSONValue[string]);
    void spawnDeviceThreads();
    void killDeviceThreads();

    void processMessage(scope const(ubyte)[] msgbuf, void delegate(scope const(ubyte)[]) responseWriter);
}


IController newController(string type)
{
    import controller.looptx;

    switch(type) {
        case "LoopTX":
            return new LoopTXController!(Complex!float)();
        default:
            return null;
    }

    // return null;
}
