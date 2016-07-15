#include "Rts.h"

#include <stdio.h>
#include <pthread.h>

static pthread_t profilerPid;
static StgBool inited = 0;

static void *profilerThread(void *);
StgWord64 rts_getEventLogChunk(StgInt8** ptr);

void startProfiler() 
{
    if (!inited) {
        if (pthread_create(&profilerPid, NULL, profilerThread, NULL)) {
            fprintf(stderr, "Error creating profiler thread\n");
        }
    }
}

void stopProfiler() 
{
    if (inited) {
        pthread_cancel(profilerPid);
        if(pthread_join(profilerPid, NULL)) {
            fprintf(stderr, "Error terminating profiler thread \n");
        }
    }
}

void *profilerThread(void *params) 
{
    StgInt8* data;
    StgWord64 len;

    for(;;) {
        len = rts_getEventLogChunk(&data);
        if (len != 0) {
            fprintf(stdout, "Got eventlog chunk!\n");
            free(data);
        }
    }
    //fprintf(stdout, "Profiler thread\n");
    return NULL;
}