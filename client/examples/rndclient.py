import multiusrp
import numpy as np

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 2
nRXUSRP = 2


with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:
    while True:
        cmd = input("Transmit, Receive, or Quit (t/r/q): ");

        if cmd.startswith("t"):
            size = int(input("signal size: "));

            print("\tGenerating {} complex random samples...".format(size));

            signals = []
            for i in range(nTXUSRP):
                # [I+jQ, I+jQ, I+jQ, ...]
                data = np.random.uniform(-1, 1, size=size) + np.random.uniform(-1, 1, size=size) * 1j
                signals.append(data)

            usrp.transmit(signals)
            print("Done")

        elif cmd.startswith("r"):

            size = int(input("signal size: "))
            
            signals = usrp.receive(size)
            print("[Response]")
            print(signals)

        elif cmd.startswith("q"):
            usrp.shutdown()
            break;

        else:
            print("Undefined command");