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

static void *profilerReaderThread(void *params);

void startClientProfiler(char *pipeName, StgWord64 bufferSize, StgBool disableFile) 
{
    if (!inited) {
        if( access( pipeName, F_OK ) == -1 ) {
            fprintf(stdout, "Creating events pipe\n");
            unlink(pipeName);
            mkfifo(pipeName, 0600);
        }

        if (pthread_create(&profilerPid, NULL, profilerReaderThread, (void*)pipeName)) {
            fprintf(stderr, "Error creating profiler client thread\n");
        }
        inited = 1;
    }
}

void stopClientProfiler() 
{
    if (inited) {
        pthread_cancel(profilerPid);
        if(pthread_join(profilerPid, NULL)) {
            fprintf(stderr, "Error terminating profiler thread \n");
        }
        inited = 0;
    }
}

void closeEventPipe(void *pipe) {
    fprintf(stdout, "Closing events pipe\n");
    int fd = *(int*)pipe;
    close(fd);
}


void *profilerReaderThread(void *params) 
{
    char *pipeName;
    int fd;
    char buf[2 * 1024 * 1024];
    int readCount;

    fprintf(stdout, "Opening the pipe for reading\n");
    pipeName = (char *)params;
    fd = open(pipeName, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "Error opening profiler pipe: %s\n", strerror(errno));
        return NULL;
    }
    pthread_cleanup_push(closeEventPipe, (void *)&fd);

    fprintf(stdout, "Started reading cycle\n");
    do {
        readCount = read(fd, buf, sizeof(buf));
        fprintf(stdout, "Read from pipe %i\n", readCount);
    } while(readCount > 0);

    pthread_cleanup_pop(1);
    return NULL;
}