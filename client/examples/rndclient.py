import sys
sys.path.append("..")

import multiusrp
import numpy as np

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;


with multiusrp.ClientV3(IPADDR, PORT) as usrp:
    while True:
        target = input("Target ID: ");
        cmd = input("Transmit, Receive, StopTransmit, or Quit (t/r/st/q): ");

        looper = multiusrp.LoopTransmitter(usrp, "TX0")

        if cmd.startswith("t"):
            size = int(input("signal size: "));

            print("\tGenerating {} complex random samples...".format(size));

            signals = []
            for i in range(1):
                # [I+jQ, I+jQ, I+jQ, ...]
                data = np.random.uniform(-1, 1, size=size) + np.random.uniform(-1, 1, size=size) * 1j
                signals.append(data)

            looper.transmit(signals)
            print("Done")

        if cmd.startswith("st"):
            looper.stopTransmit()

        # elif cmd.startswith("r"):

        #     size = int(input("signal size: "))
            
        #     signals = usrp.receive(size)
        #     print("[Response]")
        #     print(signals)

        # elif cmd.startswith("q"):
        #     usrp.shutdown()
        #     break;

        else:
            print("Undefined command");