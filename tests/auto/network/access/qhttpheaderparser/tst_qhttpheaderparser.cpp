/****************************************************************************
**
** Copyright (C) 2022 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the test suite of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:GPL-EXCEPT$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 3 as published by the Free Software
** Foundation with exceptions as appearing in the file LICENSE.GPL3-EXCEPT
** included in the packaging of this file. Please review the following
** information to ensure the GNU General Public License requirements will
** be met: https://www.gnu.org/licenses/gpl-3.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include <QtTest/qtest.h>
#include <QObject>
#include <QtNetwork/private/qhttpheaderparser_p.h>

class tst_QHttpHeaderParser : public QObject
{
    Q_OBJECT
private Q_SLOTS:
    void constructor();
    void limitsSetters();

    void adjustableLimits_data();
    void adjustableLimits();

    // general parsing tests can be found in tst_QHttpNetworkReply
};

void tst_QHttpHeaderParser::constructor()
{
    QHttpHeaderParser parser;
    QCOMPARE(parser.getStatusCode(), 100);
    QCOMPARE(parser.getMajorVersion(), 0);
    QCOMPARE(parser.getMinorVersion(), 0);
    QCOMPARE(parser.getReasonPhrase(), QByteArray());
    QCOMPARE(parser.combinedHeaderValue("Location"), QByteArray());
    QCOMPARE(parser.maxHeaderFields(), HeaderConstants::MAX_HEADER_FIELDS);
    QCOMPARE(parser.maxHeaderFieldSize(), HeaderConstants::MAX_HEADER_FIELD_SIZE);
    QCOMPARE(parser.maxTotalHeaderSize(), HeaderConstants::MAX_TOTAL_HEADER_SIZE);
}

void tst_QHttpHeaderParser::limitsSetters()
{
    QHttpHeaderParser parser;
    parser.setMaxHeaderFields(10);
    QCOMPARE(parser.maxHeaderFields(), 10);
    parser.setMaxHeaderFieldSize(10);
    QCOMPARE(parser.maxHeaderFieldSize(), 10);
    parser.setMaxTotalHeaderSize(10);
    QCOMPARE(parser.maxTotalHeaderSize(), 10);
}

void tst_QHttpHeaderParser::adjustableLimits_data()
{
    QTest::addColumn<qsizetype>("maxFieldCount");
    QTest::addColumn<qsizetype>("maxFieldSize");
    QTest::addColumn<qsizetype>("maxTotalSize");
    QTest::addColumn<QByteArray>("headers");
    QTest::addColumn<bool>("success");

    // We pretend -1 means to not set a new limit.

    QTest::newRow("maxFieldCount-pass") << qsizetype(10) << qsizetype(-1) << qsizetype(-1)
                                        << QByteArray("Location: hi\r\n\r\n") << true;
    QTest::newRow("maxFieldCount-fail") << qsizetype(1) << qsizetype(-1) << qsizetype(-1)
                                        << QByteArray("Location: hi\r\nCookie: a\r\n\r\n") << false;

    QTest::newRow("maxFieldSize-pass") << qsizetype(-1) << qsizetype(50) << qsizetype(-1)
                                       << QByteArray("Location: hi\r\n\r\n") << true;
    constexpr char cookieHeader[] = "Cookie: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    static_assert(sizeof(cookieHeader) - 1 == 51);
    QByteArray fullHeader = QByteArray("Location: hi\r\n") + cookieHeader;
    QTest::newRow("maxFieldSize-fail") << qsizetype(-1) << qsizetype(50) << qsizetype(-1)
                                       << (fullHeader + "\r\n\r\n") << false;

    QTest::newRow("maxTotalSize-pass") << qsizetype(-1) << qsizetype(-1) << qsizetype(50)
                                       << QByteArray("Location: hi\r\n\r\n") << true;
    QTest::newRow("maxTotalSize-fail") << qsizetype(-1) << qsizetype(-1) << qsizetype(10)
                                       << QByteArray("Location: hi\r\n\r\n") << false;
}

void tst_QHttpHeaderParser::adjustableLimits()
{
    QFETCH(qsizetype, maxFieldCount);
    QFETCH(qsizetype, maxFieldSize);
    QFETCH(qsizetype, maxTotalSize);
    QFETCH(QByteArray, headers);
    QFETCH(bool, success);

    QHttpHeaderParser parser;
    if (maxFieldCount != qsizetype(-1))
        parser.setMaxHeaderFields(maxFieldCount);
    if (maxFieldSize != qsizetype(-1))
        parser.setMaxHeaderFieldSize(maxFieldSize);
    if (maxTotalSize != qsizetype(-1))
        parser.setMaxTotalHeaderSize(maxTotalSize);

    QCOMPARE(parser.parseHeaders(headers), success);
}

QTEST_MAIN(tst_QHttpHeaderParser)
#include "tst_qhttpheaderparser.moc"
