module zhelper;

import deimos.zmq.zmq;
import core.stdc.stdlib;
import core.stdc.string;

void[] s_recv_noblock(void* socket, ref bool error)
{
    zmq_msg_t message;
    zmq_msg_init(&message);
    scope(exit) zmq_msg_close(&message);

    immutable len = zmq_msg_recv(&message, socket, ZMQ_DONTWAIT);
    if(len >= 0){
        void* mem = malloc(len);
        memcpy(mem, zmq_msg_data(&message), len);
        error = false;
        return mem[0 .. len];
    }else{
        import core.stdc.errno;
        if(errno == EAGAIN)
            error = false;
        else
            error = true;
    }

    return null;
}


void s_send(void* socket, void[] data, ref bool error)
{
    int rc;
    zmq_msg_t message;
    zmq_msg_init_size(&message, data.length);
    scope(exit) zmq_msg_close(&message);

    memcpy(zmq_msg_data(&message), data.ptr, data.length);
    if(zmq_msg_send(&message, socket, ZMQ_DONTWAIT) < 0)
        error = true;
    else
        error = false;
}
