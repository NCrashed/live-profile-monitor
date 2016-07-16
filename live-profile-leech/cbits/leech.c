#include "Rts.h"

#include <stdio.h>
#include <pthread.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

static pthread_t leechPid;
static char *pipeName = NULL;
static StgBool inited = 0;
static StgBool fileDisabled = 0;
static StgBool oldBufferSize = 0;
static FILE* oldFile = NULL;

static void *leechThread(void *);

void rts_setEventLogSink(FILE *sink,
                         StgBool closePrev,
                         StgBool emitHeader);
FILE* rts_getEventLogSink(void);

StgWord64 rts_getEventLogChunk(StgInt8** ptr);

void rts_resizeEventLog(StgWord64 size);
StgWord64 rts_getEventLogBuffersSize(void);

void startLeech(char *pName, StgWord64 bufferSize, StgBool disableFile) 
{
    if (!inited) {
        pipeName = strdup(pName);

        if( access( pipeName, F_OK ) == -1 ) {
            fprintf(stdout, "Leech: Creating events pipe\n");
            unlink(pipeName);
            mkfifo(pipeName, 0600);
        }

        oldBufferSize = rts_getEventLogBuffersSize();
        rts_resizeEventLog(bufferSize);

        fileDisabled = disableFile;
        if (disableFile) {
            oldFile = rts_getEventLogSink();
            rts_setEventLogSink(NULL, 0, 0);
        }

        if (pthread_create(&leechPid, NULL, leechThread, (void*)pipeName)) {
            fprintf(stderr, "Leech: Error creating leech thread\n");
        }
        inited = 1;
    }
}

void stopLeech() 
{
    if (inited) {
        pthread_cancel(leechPid);
        if(pthread_join(leechPid, NULL)) {
            fprintf(stderr, "Leech: Error terminating leech thread \n");
        }

        if (fileDisabled) {
            rts_setEventLogSink(oldFile, 0, 0);
        }
        rts_resizeEventLog(oldBufferSize);

        if (pipeName != NULL) {
            free(pipeName);
        }
        inited = 0;
    }
}

void closeEventPipe(void *pipe) {
    fprintf(stdout, "Leech: Closing events pipe\n");
    int fd = *(int*)pipe;
    close(fd);
}

void *leechThread(void *params) 
{
    StgInt8* data;
    StgWord64 len;
    char *pipeName;
    int fd;

    fprintf(stdout, "Leech: Opening the pipe for writing\n");
    pipeName = (char *)params;
    fd = open(pipeName, O_WRONLY);
    pthread_cleanup_push(closeEventPipe, (void *)&fd);

    fprintf(stdout, "Leech: Started writing cycle\n");
    for(;;) {
        len = rts_getEventLogChunk(&data);
        if (len != 0) {
            fprintf(stdout, "Leech: Got eventlog chunk! %i\n", len);

            StgWord64 writen = 0;
            do {
                writen = write(fd, data, len);
            } while (writen > 0 && writen < len);
            if (writen < 0) {
                char* err = strerror(errno);
                fprintf(stderr, "Leech: Error writing to event pipe: %s\n", err);
            }

            free(data);
        }
    }

    pthread_cleanup_pop(1);
    return NULL;
}
