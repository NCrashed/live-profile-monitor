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
#include <string.h>

#endif

void startLeech(char *pName, StgWord64 bufferSize, StgBool disableFile);
void stopLeech(void);

void rts_setEventLogSink(FILE *sink,
                         StgBool closePrev,
                         StgBool emitHeader);
FILE* rts_getEventLogSink(void);

StgWord64 rts_getEventLogChunk(StgInt8** ptr);

void rts_resizeEventLog(StgWord64 size);
StgWord64 rts_getEventLogBuffersSize(void);


#ifdef mingw32_HOST_OS // Windows implementation

static HANDLE leechPid;
static char *pipeName = NULL;
static StgBool inited = 0;
static StgBool fileDisabled = 0;
static StgBool oldBufferSize = 0;
static StgWord64 bufferSize = 0;
static StgBool terminate = 0;
static FILE* oldFile = NULL;

DWORD WINAPI leechThread( LPVOID lpParam );

#define DBG(x) fprintf(stdout, x "\n"); fflush(stdout)

void startLeech(char *pName, StgWord64 bSize, StgBool disableFile) 
{
    if (!inited) {
        pipeName = strdup(pName);
        bufferSize = bSize;
        oldBufferSize = rts_getEventLogBuffersSize();
        rts_resizeEventLog(bufferSize);

        fileDisabled = disableFile;
        if (disableFile) {
            oldFile = rts_getEventLogSink();
            rts_setEventLogSink(NULL, 0, 0);
        }

        // spawn thread 
        _tprintf(TEXT("Leech: spawn thread\n"));
        leechPid = CreateThread( 
            NULL,                   // default security attributes
            0,                      // use default stack size  
            leechThread,            // thread function name
            (LPVOID)pipeName,       // argument to thread function 
            0,                      // use default creation flags 
            NULL);                  // doesn't return the thread identifier 

        if (leechPid == NULL) 
        {
           _tprintf(TEXT("Create leech thread is failed\n"));
           ExitProcess(2);
        }
        inited = 1;
    }
}

void stopLeech(void) 
{
    if (inited) {
        terminate = 1;
        if(WaitForSingleObject(leechPid, INFINITE) == WAIT_FAILED) {
            _tprintf(TEXT("Error terminating leech thread \n"));
        }
        CloseHandle(leechPid);

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

DWORD WINAPI leechThread( LPVOID lpParam )
{
    LPTSTR pipeName;
    HANDLE hPipe;
    StgInt8* data;
    StgWord64 len;
    DWORD dwMode;
    BOOL fSuccess = FALSE;

    _tprintf(TEXT("Leech: Opening the pipe for writing\n"));
    pipeName = (char *)lpParam;
    while (1) 
    {
        hPipe = CreateFile( 
            pipeName,       // pipe name 
            GENERIC_WRITE,  // read access  
            0,              // no sharing 
            NULL,           // default security attributes
            OPEN_EXISTING,  // opens existing pipe 
            0,              // default attributes 
            NULL);          // no template file 
 
        // Break if the pipe handle is valid. 
        if (hPipe != INVALID_HANDLE_VALUE) {
            break; 
        }
 
        // Exit if an error other than ERROR_PIPE_BUSY occurs. 
 
        if (GetLastError() != ERROR_PIPE_BUSY) 
        {
            _tprintf( TEXT("Could not open profiler pipe. GLE=%d\n"), GetLastError() ); 
            PrintLastErrorAsString();
            return -1;
        }

        // All pipe instances are busy, so wait for 20 seconds. 
        if ( ! WaitNamedPipe(pipeName, 20000)) 
        {
            _tprintf( TEXT("Could not open profiler pipe: 20 second wait timed out.")); 
            fflush(stdout);
            return -1;
        }
    } 

    // Set message mode
    dwMode = PIPE_READMODE_MESSAGE; 
    fSuccess = SetNamedPipeHandleState( 
        hPipe,    // pipe handle 
        &dwMode,  // new pipe mode 
        NULL,     // don't set maximum bytes 
        NULL);    // don't set maximum time 
    if (!fSuccess) 
    {
        _tprintf( TEXT("SetNamedPipeHandleState for profile pipe failed. GLE=%d\n"), GetLastError() ); 
        PrintLastErrorAsString();
        return -1;
    }

    fprintf(stdout, "Leech: Started writing cycle\n");
    while (terminate == 0) {
        len = rts_getEventLogChunk(&data);
        if (len != 0) {
            StgWord64 writen = 0;
            StgInt8 *dataLeft = data;
            do {
                fSuccess = WriteFile( 
                    hPipe,        // handle to pipe 
                    dataLeft,     // buffer to write from 
                    len,          // number of bytes to write 
                    &writen,      // number of bytes written 
                    NULL);        // not overlapped I/O 

                if (!fSuccess)
                {   
                    _tprintf(TEXT("Leech: WriteFile failed, GLE=%d.\n"), GetLastError()); 
                    break;
                }

                len = len - writen;
                dataLeft = dataLeft + writen;
            } while (writen < len);

            free(data);
        }
        SwitchToThread();
    }

    _tprintf(TEXT("Leech: Closing pipe"));
    fflush(stdout);
    FlushFileBuffers(hPipe); 
    DisconnectNamedPipe(hPipe); 
    CloseHandle(hPipe); 
    return NULL;
}

#else // POSIX implementation 

static pthread_t leechPid;
static char *pipeName = NULL;
static StgBool inited = 0;
static StgBool fileDisabled = 0;
static StgBool oldBufferSize = 0;
static FILE* oldFile = NULL;

static void *leechThread(void *);

void startLeech(char *pName, StgWord64 bufferSize, StgBool disableFile) 
{
    if (!inited) {
        pipeName = strdup(pName);

        if( access( pipeName, F_OK ) > 0 ) {
            fprintf(stdout, "Leech: delete old pipe\n");
            unlink(pipeName);
            system("rm pipeName");
        }
        fprintf(stdout, "Leech: Creating events pipe\n");
        mkfifo(pipeName, 0600);

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

void stopLeech(void) 
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
            StgWord64 writen = 0;
            StgInt8 *dataLeft = data;
            do {
                writen = write(fd, dataLeft, len);
                len = len - writen;
                dataLeft = dataLeft + writen;
            } while (writen >= 0 && writen < len);
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

#endif