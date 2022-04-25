/****************************************************************************
**
** Copyright (C) 2022 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the plugins of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:COMM$
**
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** $QT_END_LICENSE$
**
**
**
**
**
**
**
**
**
**
**
**
**
**
**
**
**
**
**
******************************************************************************/

#include <AppKit/AppKit.h>

#include "qcocoawindowmanager.h"
#include "qcocoawindow.h"

#include <QtCore/private/qcore_mac_p.h>

#include <QtGui/qguiapplication.h>
#include <QtGui/qwindow.h>

QT_BEGIN_NAMESPACE

QCocoaWindowManager::QCocoaWindowManager()
{
    if (NSApp) {
        initialize();
    } else {
        m_applicationDidFinishLaunchingObserver = QMacNotificationObserver(nil,
            NSApplicationDidFinishLaunchingNotification, [this] { initialize(); });
    }
}

void QCocoaWindowManager::initialize()
{
    Q_ASSERT(NSApp);

    // Whenever the modalWindow property of NSApplication changes we have a new
    // modal session running. Observing the app modal window instead of our own
    // event dispatcher sessions allows us to track session started by native
    // APIs as well. We need to check the initial state as well, in case there
    // is already a modal session running.
    m_modalSessionObserver = QMacKeyValueObserver(
        NSApp, @"modalWindow", [this] { modalSessionChanged(); },
        NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew);
}

void QCocoaWindowManager::modalSessionChanged()
{
    // Make sure that no window is overlapping the modal window. This can
    // happen for e.g. splash screens, which have the NSPopUpMenuWindowLevel.
    for (auto *window : QGuiApplication::topLevelWindows()) {
        auto *platformWindow = static_cast<QCocoaWindow*>(window->handle());
        if (!platformWindow)
            continue;

        auto naturalWindowLevel = platformWindow->windowLevel(window->flags());
        if (naturalWindowLevel > NSModalPanelWindowLevel) {
            NSWindow *nativeWindow = platformWindow->nativeWindow();
            if (NSApp.modalWindow) {
                // Lower window to that of the modal windows, but no less
                nativeWindow.level = NSModalPanelWindowLevel;
                if ([nativeWindow isVisible])
                    [nativeWindow orderBack:nil];
            } else {
                // Restore window's natural window level, whatever that was
                nativeWindow.level = naturalWindowLevel;
            }
        }
    }

    // Our worksWhenModal implementation is declarative and will normally be picked
    // up by AppKit when needed, but to make sure AppKit also reflects the state
    // in the window tag, so that the window can be ordered front by clicking it,
    // we need to explicitly call setWorksWhenModal.
    for (id window in NSApp.windows) {
        if ([window isKindOfClass:[QNSPanel class]]) {
            auto *panel = static_cast<QNSPanel *>(window);
            // Call setter to tell AppKit that our state has changed
            [panel setWorksWhenModal:panel.worksWhenModal];
        }
    }
}

QT_END_NAMESPACE

