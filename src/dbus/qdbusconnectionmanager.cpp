// Copyright (C) 2016 The Qt Company Ltd.
// Copyright (C) 2016 Intel Corporation.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

#include "qdbusconnectionmanager_p.h"

#include <qcoreapplication.h>
#include <qthread.h>
#include <QtCore/private/qlocking_p.h>

#include "qdbuserror.h"
#include "qdbuspendingcall_p.h"
#include "qdbusmetatype_p.h"

#ifndef QT_NO_DBUS

QT_BEGIN_NAMESPACE

#ifdef Q_OS_WIN
static void preventDllUnload();
#endif

Q_GLOBAL_STATIC(QDBusConnectionManager, _q_manager)

QDBusConnectionPrivate *QDBusConnectionManager::busConnection(QDBusConnection::BusType type)
{
    static_assert(int(QDBusConnection::SessionBus) + int(QDBusConnection::SystemBus) == 1);
    Q_ASSERT(type == QDBusConnection::SessionBus || type == QDBusConnection::SystemBus);

    if (!qdbus_loadLibDBus())
        return nullptr;

    // we'll start in suspended delivery mode if we're in the main thread
    // (the event loop will resume delivery)
    bool suspendedDelivery = qApp && qApp->thread() == QThread::currentThread();

    const auto locker = qt_scoped_lock(defaultBusMutex);
    if (defaultBuses[type])
        return defaultBuses[type];

    QString name = QStringLiteral("qt_default_session_bus");
    if (type == QDBusConnection::SystemBus)
        name = QStringLiteral("qt_default_system_bus");
    return defaultBuses[type] = connectToBus(type, name, suspendedDelivery);
}

QDBusConnectionPrivate *QDBusConnectionManager::connection(const QString &name) const
{
    return connectionHash.value(name, nullptr);
}

void QDBusConnectionManager::removeConnection(const QString &name)
{
    QDBusConnectionPrivate *d = nullptr;
    d = connectionHash.take(name);
    if (d && !d->ref.deref())
        d->deleteLater();

    // Static objects may be keeping the connection open.
    // However, it is harmless to have outstanding references to a connection that is
    // closing as long as those references will be soon dropped without being used.

    // ### Output a warning if connections are being used after they have been removed.
}

QDBusConnectionManager::QDBusConnectionManager()
{
    // Ensure that the custom metatype registry is created before the instance
    // of this class. This will ensure that the registry is not destroyed before
    // the connection manager at application exit (see also QTBUG-58732). This
    // works with compilers that use mechanism similar to atexit() to call
    // destructurs for global statics.
    QDBusMetaTypeId::init();

    connect(this, &QDBusConnectionManager::connectionRequested,
            this, &QDBusConnectionManager::executeConnectionRequest, Qt::BlockingQueuedConnection);
    moveToThread(this);         // ugly, don't do this in other projects

#ifdef Q_OS_WIN
    // prevent the library from being unloaded on Windows. See comments in the function.
    preventDllUnload();
#endif
    defaultBuses[0] = defaultBuses[1] = nullptr;
    start();
}

QDBusConnectionManager::~QDBusConnectionManager()
{
    quit();
    wait();
}

QDBusConnectionManager* QDBusConnectionManager::instance()
{
    return _q_manager();
}

Q_DBUS_EXPORT void qDBusBindToApplication();
void qDBusBindToApplication()
{
}

void QDBusConnectionManager::setConnection(const QString &name, QDBusConnectionPrivate *c)
{
    connectionHash[name] = c;
    c->name = name;
}

void QDBusConnectionManager::run()
{
    exec();

    // cleanup:
    const auto locker = qt_scoped_lock(mutex);
    for (QDBusConnectionPrivate *d : std::as_const(connectionHash)) {
        if (!d->ref.deref()) {
            delete d;
        } else {
            d->closeConnection();
            d->moveToThread(nullptr);     // allow it to be deleted in another thread
        }
    }
    connectionHash.clear();

    // allow deletion from any thread without warning
    moveToThread(nullptr);
}

QDBusConnectionPrivate *QDBusConnectionManager::connectToBus(QDBusConnection::BusType type, const QString &name,
                                                             bool suspendedDelivery)
{
    ConnectionRequestData data;
    data.type = ConnectionRequestData::ConnectToStandardBus;
    data.busType = type;
    data.name = &name;
    data.suspendedDelivery = suspendedDelivery;

    emit connectionRequested(&data);
    if (suspendedDelivery && data.result->connection)
        data.result->enableDispatchDelayed(qApp); // qApp was checked in the caller

    return data.result;
}

QDBusConnectionPrivate *QDBusConnectionManager::connectToBus(const QString &address, const QString &name)
{
    ConnectionRequestData data;
    data.type = ConnectionRequestData::ConnectToBusByAddress;
    data.busAddress = &address;
    data.name = &name;
    data.suspendedDelivery = false;

    emit connectionRequested(&data);
    return data.result;
}

QDBusConnectionPrivate *QDBusConnectionManager::connectToPeer(const QString &address, const QString &name)
{
    ConnectionRequestData data;
    data.type = ConnectionRequestData::ConnectToPeerByAddress;
    data.busAddress = &address;
    data.name = &name;
    data.suspendedDelivery = false;

    emit connectionRequested(&data);
    return data.result;
}

void QDBusConnectionManager::executeConnectionRequest(QDBusConnectionManager::ConnectionRequestData *data)
{
    const auto locker = qt_scoped_lock(mutex);
    const QString &name = *data->name;
    QDBusConnectionPrivate *&d = data->result;

    // check if the connection exists by name
    d = connection(name);
    if (d || name.isEmpty())
        return;

    d = new QDBusConnectionPrivate;
    DBusConnection *c = nullptr;
    QDBusErrorInternal error;
    switch (data->type) {
    case ConnectionRequestData::ConnectToStandardBus:
        switch (data->busType) {
        case QDBusConnection::SystemBus:
            c = q_dbus_bus_get_private(DBUS_BUS_SYSTEM, error);
            break;
        case QDBusConnection::SessionBus:
            c = q_dbus_bus_get_private(DBUS_BUS_SESSION, error);
            break;
        case QDBusConnection::ActivationBus:
            c = q_dbus_bus_get_private(DBUS_BUS_STARTER, error);
            break;
        }
        break;

    case ConnectionRequestData::ConnectToBusByAddress:
    case ConnectionRequestData::ConnectToPeerByAddress:
        c = q_dbus_connection_open_private(data->busAddress->toUtf8().constData(), error);
        if (c && data->type == ConnectionRequestData::ConnectToBusByAddress) {
            // register on the bus
            if (!q_dbus_bus_register(c, error)) {
                q_dbus_connection_unref(c);
                c = nullptr;
            }
        }
        break;
    }

    setConnection(name, d);
    if (data->type == ConnectionRequestData::ConnectToPeerByAddress) {
        d->setPeer(c, error);
    } else {
        // create the bus service
        // will lock in QDBusConnectionPrivate::connectRelay()
        d->setConnection(c, error);
        d->createBusService();
        if (c && data->suspendedDelivery)
            d->setDispatchEnabled(false);
    }
}

void QDBusConnectionManager::createServer(const QString &address, QDBusServer *server)
{
    QMetaObject::invokeMethod(
            this,
            [&address, server] {
                QDBusErrorInternal error;
                QDBusConnectionPrivate *d = new QDBusConnectionPrivate;
                d->setServer(server, q_dbus_server_listen(address.toUtf8().constData(), error),
                             error);
            },
            Qt::BlockingQueuedConnection);
}

QT_END_NAMESPACE

#include "moc_qdbusconnectionmanager_p.cpp"

#ifdef Q_OS_WIN
#  include <qt_windows.h>

QT_BEGIN_NAMESPACE
static void preventDllUnload()
{
    // Thread termination is really wacky on Windows. For some reason we don't
    // understand, exiting from the thread may try to unload the DLL. Since the
    // QDBusConnectionManager thread runs until the DLL is unloaded, we've got
    // a deadlock: the main thread is waiting for the manager thread to exit,
    // but the manager thread is attempting to acquire a lock to unload the DLL.
    //
    // We work around the issue by preventing the unload from happening in the
    // first place.
    //
    // For this trick, see the blog post titled "What is the point of FreeLibraryAndExitThread?"
    // https://devblogs.microsoft.com/oldnewthing/20131105-00/?p=2733

    static HMODULE self;
    GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                      GET_MODULE_HANDLE_EX_FLAG_PIN,
                      reinterpret_cast<const wchar_t *>(&self), // any address in this DLL
                      &self);
}
QT_END_NAMESPACE
#endif

#endif // QT_NO_DBUS
