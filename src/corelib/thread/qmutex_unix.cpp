// Copyright (C) 2016 The Qt Company Ltd.
// Copyright (C) 2015 Olivier Goffart <ogoffart@woboq.com>
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

#include "qplatformdefs.h"
#include "qmutex.h"
#include "qstring.h"
#include "qelapsedtimer.h"
#include "qatomic.h"
#include "qmutex_p.h"
#include <errno.h>
#include <sys/time.h>
#include <time.h>
#include "private/qcore_unix_p.h"

#if defined(Q_OS_VXWORKS) && defined(wakeup)
#undef wakeup
#endif

QT_BEGIN_NAMESPACE

static void report_error(int code, const char *where, const char *what)
{
    if (code != 0)
        qErrnoWarning(code, "%s: %s failure", where, what);
}

QMutexPrivate::QMutexPrivate()
{
    report_error(sem_init(&semaphore, 0, 0), "QMutex", "sem_init");
}

QMutexPrivate::~QMutexPrivate()
{

    report_error(sem_destroy(&semaphore), "QMutex", "sem_destroy");
}

bool QMutexPrivate::wait(int timeout)
{
    int errorCode;
    if (timeout < 0) {
        do {
            errorCode = sem_wait(&semaphore);
        } while (errorCode && errno == EINTR);
        report_error(errorCode, "QMutex::lock()", "sem_wait");
    } else {
        timespec ts;
        report_error(clock_gettime(CLOCK_REALTIME, &ts), "QMutex::lock()", "clock_gettime");
        ts.tv_sec += timeout / 1000;
        ts.tv_nsec += timeout % 1000 * Q_UINT64_C(1000) * 1000;
        normalizedTimespec(ts);
        do {
            errorCode = sem_timedwait(&semaphore, &ts);
        } while (errorCode && errno == EINTR);

        if (errorCode && errno == ETIMEDOUT)
            return false;
        report_error(errorCode, "QMutex::lock()", "sem_timedwait");
    }
    return true;
}

void QMutexPrivate::wakeUp() noexcept
{
    report_error(sem_post(&semaphore), "QMutex::unlock", "sem_post");
}

QT_END_NAMESPACE
