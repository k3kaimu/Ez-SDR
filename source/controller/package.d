module controller;

import std.socket;

interface IController
{
    void registerDevice(IDevice);
    void spawnDeviceThread();
    void killDeviceThread();
    void processMessage(Socket, scope void[] msgbuf);
}
