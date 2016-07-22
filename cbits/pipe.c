#include "Rts.h"

#ifdef mingw32_HOST_OS // Dependencies for Windows 

#include <windows.h>
#include <tchar.h>
#include <strsafe.h>

#include <conio.h>
#include <stdio.h>
#include <string.h>

#else // Dependencies for POSIX 

#include <stdio.h>
#include <pthread.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#endif 

// Haskell callback that we call when some data from pipe is read
typedef void (*haskellCallback)(unsigned char *, int);

void startProfilerPipe(char *pipeName, StgWord64 bs, haskellCallback cb) ;
void stopProfilerPipe(void);

#ifdef mingw32_HOST_OS // Windows implementation

static HANDLE profilerPid;
static StgBool inited = 0;
static char *pipeName = NULL;
static haskellCallback callback = NULL;
static StgWord64 bufferSize = 0;
static StgBool terminate = 0;

DWORD WINAPI profilerReaderThread( LPVOID lpParam );

#define DBG(x) fprintf(stdout, x "\n"); fflush(stdout)

void startProfilerPipe(char *pName, StgWord64 bs, haskellCallback cb) 
{
    if (!inited) {
        pipeName = strdup(pName);
        callback = cb;
        bufferSize = bs;
        terminate = 0;

        // spawn thread 
        profilerPid = CreateThread( 
            NULL,                   // default security attributes
            0,                      // use default stack size  
            profilerReaderThread,   // thread function name
            (LPVOID)pipeName,       // argument to thread function 
            0,                      // use default creation flags 
            NULL);                  // doesn't return the thread identifier 

        if (profilerPid == NULL) 
        {
           _tprintf(TEXT("Create profiler reader thread is failed\n"));
           ExitProcess(2);
        }

        inited = 1;
    }
}

void stopProfilerPipe(void) 
{
    if (inited) {
        terminate = 1;
        if(WaitForSingleObject(profilerPid, INFINITE) == WAIT_FAILED) {
            _tprintf(TEXT("Error terminating profiler thread \n"));
        }
        CloseHandle(profilerPid);
        inited = 0;
    }
} 


static void PrintLastErrorAsString(void)
{
    //Get the error message, if any.
    DWORD errorMessageID = GetLastError();
    if(errorMessageID == 0)
        return; //No error message has been recorded

    LPSTR messageBuffer = NULL;
    size_t size = FormatMessageA(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                                 NULL, errorMessageID, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)&messageBuffer, 0, NULL);

    _tprintf("%s\n", messageBuffer);
    fflush(stdout);

    //Free the buffer.
    LocalFree(messageBuffer);
}



DWORD WINAPI profilerReaderThread( LPVOID lpParam )
{
    LPTSTR pipeName;
    HANDLE hPipe;
    TCHAR *buf;
    DWORD readCount;
    DWORD dwMode;
    BOOL fSuccess = FALSE;

    buf = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, bufferSize);

    _tprintf(TEXT("Pipe: Opening the pipe for reading\n"));
    pipeName = (char *)lpParam;
    hPipe = CreateNamedPipe( 
        pipeName,                 // pipe name 
        PIPE_ACCESS_DUPLEX,       // write access 
        PIPE_TYPE_MESSAGE |       // message type pipe 
        PIPE_READMODE_MESSAGE |   // message-read mode 
        PIPE_WAIT,                // blocking mode 
        PIPE_UNLIMITED_INSTANCES, // max. instances  
        bufferSize,               // output buffer size 
        bufferSize,               // input buffer size 
        0,                        // client time-out 
        NULL);                    // default security attribute 

    if (hPipe == INVALID_HANDLE_VALUE) 
    {
        _tprintf(TEXT("Pipe: CreateNamedPipe failed for leech pipe, GLE=%d.\n")
            , GetLastError()); 
        PrintLastErrorAsString();
        return -1;
    }

    // Read from the pipe. 
    while(terminate == 0) {
        do 
        { 
            fSuccess = ReadFile( 
                hPipe,       // pipe handle 
                buf,         // buffer to receive reply 
                bufferSize,  // size of buffer 
                &readCount,  // number of bytes read 
                NULL);       // not overlapped 

            if ( !fSuccess && GetLastError() != ERROR_MORE_DATA )
                break; 

            if (readCount > 0 && callback != NULL) {
                callback(buf, readCount);
            }
        } while (!fSuccess);  // repeat loop if ERROR_MORE_DATA 

        if (!fSuccess && GetLastError() != ERROR_PIPE_LISTENING)
        {
            _tprintf( TEXT("ReadFile from pipe failed. GLE=%d\n"), GetLastError() );
            PrintLastErrorAsString();
        }
        SwitchToThread();
    }

    HeapFree(GetProcessHeap(), 0, buf);
    CloseHandle(hPipe);
    return NULL;
}

#else // POSIX and pthreads implementation

static pthread_t profilerPid;
static StgBool inited = 0;
static char *pipeName = NULL;
static haskellCallback callback = NULL;
static StgWord64 bufferSize = 0;
static StgBool terminate = 0;

static void *profilerReaderThread(void *params);

void startProfilerPipe(char *pName, StgWord64 bs, haskellCallback cb) 
{
    if (!inited) {
        pipeName = strdup(pName);

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

#endif