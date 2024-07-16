module controller;

import std.complex;
import std.socket;
import std.json;

import device;
import controller.looptx;


interface IController
{
    void setup(IDevice[], JSONValue[string]);
    void spawnDeviceThreads();
    void killDeviceThreads();
    void processMessage(scope void[] msgbuf, void delegate(scope void[]) responseWriter);
}


IController newController(string type)
{
    switch(type) {
        case "LoopTX":
            return new LoopTXController!(Complex!float)();
        default:
            return null;
    }

    // return null;
}
