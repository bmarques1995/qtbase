// Copyright (C) 2016 The Qt Company Ltd.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

#ifndef QFUNCTIONS_VXWORKS_H
#define QFUNCTIONS_VXWORKS_H

#include <QtCore/qglobal.h>

#ifdef Q_OS_VXWORKS

#include <unistd.h>
#include <pthread.h>
#include <dirent.h>
#include <signal.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#if defined(_WRS_KERNEL)
#include <sys/times.h>
#else
#include <sys/time.h>
#endif
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <netinet/in.h>

// VxWorks has public header mbuf.h which defines following variables for DKM.
// Let's undef those to because they overlap with Qt variable names-
// File mbuf.h is included in headers <netinet/in.h> <net/if.h>, so make sure
// that those are included before undef's.
#if defined(mbuf)
#  undef mbuf
#endif
#if defined(m_data)
#  undef m_data
#endif
#if defined(m_type)
#  undef m_type
#endif
#if defined(m_next)
#  undef m_next
#endif
#if defined(m_len)
#  undef m_len
#endif
#if defined(m_flags)
#  undef m_flags
#endif
#if defined(m_hdr)
#  undef m_hdr
#endif
#if defined(m_ext)
#  undef m_ext
#endif
#if defined(m_act)
#  undef m_act
#endif
#if defined(m_nextpkt)
#  undef m_nextpkt
#endif
#if defined(m_pkthdr)
#  undef m_pkthdr
#endif

QT_BEGIN_NAMESPACE

#ifdef QT_BUILD_CORE_LIB
#endif

QT_END_NAMESPACE

#ifndef RTLD_LOCAL
#define RTLD_LOCAL  0
#endif

#ifndef NSIG
#define NSIG _NSIGS
#endif

#ifdef __cplusplus
extern "C" {
#endif

// isascii is missing (sometimes!!)
#ifndef isascii
inline int isascii(int c)  { return (c & 0x7f); }
#endif

// no lfind() - used by the TIF image format
void *lfind(const void* key, const void* base, size_t* elements, size_t size,
            int (*compare)(const void*, const void*));

// no rand_r(), but rand()
// NOTE: this implementation is wrong for multi threaded applications,
// but there is no way to get it right on VxWorks (in kernel mode)
#if defined(_WRS_KERNEL)
int rand_r(unsigned int * /*seedp*/);
#endif

#if defined(VXWORKS_DKM) || defined(VXWORKS_RTP)
int gettimeofday(struct timeval *, void *);
#else
// gettimeofday() is declared, but is missing from the library.
// It IS however defined in the Curtis-Wright X11 libraries, so
// we have to make the symbol 'weak'
int gettimeofday(struct timeval *tv, void /*struct timezone*/ *) __attribute__((weak));
#endif

// symlinks are not supported (lstat is now just a call to stat - see qplatformdefs.h)
int symlink(const char *, const char *);
ssize_t readlink(const char *, char *, size_t);

// there's no truncate(), but ftruncate() support...
int truncate(const char *path, off_t length);

// VxWorks doesn't know about passwd & friends.
// in order to avoid patching the unix fs path everywhere
// we introduce some dummy functions that simulate a single
// 'root' user on the system.

uid_t getuid();
gid_t getgid();
uid_t geteuid();

struct group {
    char   *gr_name;       /* group name */
    char   *gr_passwd;     /* group password */
    gid_t   gr_gid;        /* group ID */
    char  **gr_mem;        /* group members */
};

struct group *getgrgid(gid_t gid);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // Q_OS_VXWORKS
#endif // QFUNCTIONS_VXWORKS_H
