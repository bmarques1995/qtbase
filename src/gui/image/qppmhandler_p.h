/****************************************************************************
**
** Copyright (C) 2021 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the QtGui module of the Qt Toolkit.
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
****************************************************************************/

#ifndef QPPMHANDLER_P_H
#define QPPMHANDLER_P_H

//
//  W A R N I N G
//  -------------
//
// This file is not part of the Qt API. It exists purely as an
// implementation detail. This header file may change from version to
// version without notice, or even be removed.
//
// We mean it.
//

#include <QtGui/private/qtguiglobal_p.h>
#include "QtGui/qimageiohandler.h"

#ifndef QT_NO_IMAGEFORMAT_PPM

QT_BEGIN_NAMESPACE

class QByteArray;
class QPpmHandler : public QImageIOHandler
{
public:
    QPpmHandler();
    bool canRead() const override;
    bool read(QImage *image) override;
    bool write(const QImage &image) override;

    static bool canRead(QIODevice *device, QByteArray *subType = nullptr);

    QVariant option(ImageOption option) const override;
    void setOption(ImageOption option, const QVariant &value) override;
    bool supportsOption(ImageOption option) const override;

private:
    bool readHeader();
    enum State {
        Ready,
        ReadHeader,
        Error
    };
    State state;
    char type;
    int width;
    int height;
    int mcc;
    mutable QByteArray subType;
};

QT_END_NAMESPACE

#endif // QT_NO_IMAGEFORMAT_PPM

#endif // QPPMHANDLER_P_H
