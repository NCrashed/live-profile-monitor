#include "Rts.h"

#include <stdio.h>
#include <pthread.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

// Haskell callback that we call when some data from pipe is read
typedef void (*haskellCallback)(unsigned char *, int);

static pthread_t profilerPid;
static StgBool inited = 0;
static haskellCallback callback = NULL;
static StgWord64 bufferSize = 0;
static StgBool terminate = 0;

static void *profilerReaderThread(void *params);

void startProfilerPipe(char *pipeName, StgWord64 bs, haskellCallback cb) 
{
    if (!inited) {
        if( access( pipeName, F_OK ) == -1 ) {
            fprintf(stdout, "Pipe: Creating events pipe\n");
            unlink(pipeName);
            mkfifo(pipeName, 0600);
        }

        callback = cb;
        bufferSize = bs;
        terminate = 0;
        if (pthread_create(&profilerPid, NULL, profilerReaderThread, (void*)pipeName)) {
            fprintf(stderr, "Pipe: Error creating profiler client thread\n");
        }
        inited = 1;
    }
}

void stopProfilerPipe(void) 
{
    if (inited) {
        terminate = 1;
        if(pthread_join(profilerPid, NULL)) {
            fprintf(stderr, "Error terminating profiler thread \n");
        }
        inited = 0;
    }
}

static void closeEventPipe(void *pipe) {
    fprintf(stdout, "Pipe: Closing events pipe\n");
    int fd = *(int*)pipe;
    close(fd);
}

static void cleanReaderBuffer(void *buff) {
    free(buff);
}

void *profilerReaderThread(void *params) 
{
    char *pipeName;
    int fd;
    unsigned char *buf;
    int readCount;

    buf = malloc(bufferSize);
    pthread_cleanup_push(cleanReaderBuffer, (void *)buf);

    fprintf(stdout, "Pipe: Opening the pipe for reading\n");
    pipeName = (char *)params;
    fd = open(pipeName, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "Pipe: Error opening profiler pipe: %s\n", strerror(errno));
        return NULL;
    }
    pthread_cleanup_push(closeEventPipe, (void *)&fd);

    fprintf(stdout, "Pipe: Started reading cycle\n");
    do {
        readCount = read(fd, buf, sizeof(buf));
        if (readCount > 0 && callback != NULL) {
            callback(buf, readCount);
        }
    } while(readCount > 0 && terminate == 0);

    pthread_cleanup_pop(1);
    pthread_cleanup_pop(1);
    return NULL;
}