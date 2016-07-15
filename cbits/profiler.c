#include "Rts.h"

#include <stdio.h>
#include <pthread.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

static pthread_t profilerPid;
static StgBool inited = 0;

static void *profilerThread(void *);
static void *testReaderThread(void *params);

StgWord64 rts_getEventLogChunk(StgInt8** ptr);

void startProfiler(char *pipeName) 
{
    if (!inited) {
        fprintf(stdout, "Creating events pipe\n");
        unlink(pipeName);
        mkfifo(pipeName, 0600);

        if (pthread_create(&profilerPid, NULL, profilerThread, (void*)pipeName)) {
            fprintf(stderr, "Error creating profiler thread\n");
        }
        if (pthread_create(&profilerPid, NULL, testReaderThread, (void*)pipeName)) {
            fprintf(stderr, "Error creating profiler test thread\n");
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

void closeEventPipe(void *pipe) {
    fprintf(stdout, "Closing events pipe\n");
    int fd = *(int*)pipe;
    close(fd);
}

void *profilerThread(void *params) 
{
    StgInt8* data;
    StgWord64 len;
    char *pipeName;
    int fd;

    fprintf(stdout, "Opening the pipe for writing\n");
    pipeName = (char *)params;
    fd = open(pipeName, O_WRONLY);
    pthread_cleanup_push(closeEventPipe, (void *)&fd);

    fprintf(stdout, "Started writing cycle\n");
    for(;;) {
        len = rts_getEventLogChunk(&data);
        if (len != 0) {
            fprintf(stdout, "Got eventlog chunk! %i\n", len);

            StgWord64 writen = 0;
            do {
                writen = write(fd, data, len);
            } while (writen > 0 && writen < len);
            if (writen < 0) {
                char* err = strerror(errno);
                fprintf(stderr, "Error writing to event pipe: %s\n", err);
            }

            free(data);
        }
    }

    pthread_cleanup_pop(1);
    return NULL;
}

void *testReaderThread(void *params) 
{
    char *pipeName;
    int fd;
    char buf[2 * 1024 * 1024];
    int readCount;

    fprintf(stdout, "Opening the pipe for reading\n");
    pipeName = (char *)params;
    fd = open(pipeName, O_RDONLY);
    pthread_cleanup_push(closeEventPipe, (void *)&fd);

    fprintf(stdout, "Started reading cycle\n");
    do {
        readCount = read(fd, buf, sizeof(buf));
        fprintf(stdout, "Read from pipe %i\n", readCount);
    } while(readCount > 0);

    pthread_cleanup_pop(1);
    return NULL;
}