/****************************************************************************
**
** Copyright (C) 2022 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the QtCore module of the Qt Toolkit.
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

#include "qlocale_p.h"

#include "qstringlist.h"
#include "qvariant.h"
#include "qdatetime.h"

#ifdef Q_OS_DARWIN
#include "private/qcore_mac_p.h"
#include <CoreFoundation/CoreFoundation.h>
#endif

QT_BEGIN_NAMESPACE

/******************************************************************************
** Wrappers for Mac locale system functions
*/

static QString getMacLocaleName()
{
    QCFType<CFLocaleRef> l = CFLocaleCopyCurrent();
    CFStringRef locale = CFLocaleGetIdentifier(l);
    return QString::fromCFString(locale);
}

static QVariant macMonthName(int month, QSystemLocale::QueryType type)
{
    month -= 1;
    if (month < 0 || month > 11)
        return {};

    QCFType<CFDateFormatterRef> formatter
        = CFDateFormatterCreate(0, QCFType<CFLocaleRef>(CFLocaleCopyCurrent()),
                                kCFDateFormatterNoStyle,  kCFDateFormatterNoStyle);

    CFDateFormatterKey formatterType;
    switch (type) {
        case QSystemLocale::MonthNameLong:
            formatterType = kCFDateFormatterMonthSymbols;
            break;
        case QSystemLocale::MonthNameShort:
            formatterType = kCFDateFormatterShortMonthSymbols;
            break;
        case QSystemLocale::MonthNameNarrow:
            formatterType = kCFDateFormatterVeryShortMonthSymbols;
            break;
        case QSystemLocale::StandaloneMonthNameLong:
            formatterType = kCFDateFormatterStandaloneMonthSymbols;
            break;
        case QSystemLocale::StandaloneMonthNameShort:
            formatterType = kCFDateFormatterShortStandaloneMonthSymbols;
            break;
        case QSystemLocale::StandaloneMonthNameNarrow:
            formatterType = kCFDateFormatterVeryShortStandaloneMonthSymbols;
            break;
        default:
            qWarning("macMonthName: Unsupported query type %d", type);
            return {};
    }
    QCFType<CFArrayRef> values
        = static_cast<CFArrayRef>(CFDateFormatterCopyProperty(formatter, formatterType));

    if (values != 0) {
        CFStringRef cfstring = static_cast<CFStringRef>(CFArrayGetValueAtIndex(values, month));
        return QString::fromCFString(cfstring);
    }
    return {};
}

static QVariant macDayName(int day, QSystemLocale::QueryType type)
{
    if (day < 1 || day > 7)
        return {};

    QCFType<CFDateFormatterRef> formatter
        = CFDateFormatterCreate(0, QCFType<CFLocaleRef>(CFLocaleCopyCurrent()),
                                kCFDateFormatterNoStyle,  kCFDateFormatterNoStyle);

    CFDateFormatterKey formatterType;
    switch (type) {
    case QSystemLocale::DayNameLong:
        formatterType = kCFDateFormatterWeekdaySymbols;
        break;
    case QSystemLocale::DayNameShort:
        formatterType = kCFDateFormatterShortWeekdaySymbols;
        break;
    case QSystemLocale::DayNameNarrow:
        formatterType = kCFDateFormatterVeryShortWeekdaySymbols;
        break;
    case QSystemLocale::StandaloneDayNameLong:
        formatterType = kCFDateFormatterStandaloneWeekdaySymbols;
        break;
    case QSystemLocale::StandaloneDayNameShort:
        formatterType = kCFDateFormatterShortStandaloneWeekdaySymbols;
        break;
    case QSystemLocale::StandaloneDayNameNarrow:
        formatterType = kCFDateFormatterVeryShortStandaloneWeekdaySymbols;
        break;
    default:
        qWarning("macDayName: Unsupported query type %d", type);
        return {};
    }
    QCFType<CFArrayRef> values =
            static_cast<CFArrayRef>(CFDateFormatterCopyProperty(formatter, formatterType));

    if (values != 0) {
        CFStringRef cfstring = static_cast<CFStringRef>(CFArrayGetValueAtIndex(values, day % 7));
        return QString::fromCFString(cfstring);
    }
    return {};
}

static QVariant macDateToString(QDate date, bool short_format)
{
    QCFType<CFDateRef> myDate = QDateTime(date, QTime()).toCFDate();
    QCFType<CFLocaleRef> mylocale = CFLocaleCopyCurrent();
    CFDateFormatterStyle style = short_format ? kCFDateFormatterShortStyle : kCFDateFormatterLongStyle;
    QCFType<CFDateFormatterRef> myFormatter
        = CFDateFormatterCreate(kCFAllocatorDefault,
                                mylocale, style,
                                kCFDateFormatterNoStyle);
    return QString::fromCFString(CFDateFormatterCreateStringWithDate(0, myFormatter, myDate));
}

static QVariant macTimeToString(QTime time, bool short_format)
{
    QCFType<CFDateRef> myDate = QDateTime(QDate::currentDate(), time).toCFDate();
    QCFType<CFLocaleRef> mylocale = CFLocaleCopyCurrent();
    CFDateFormatterStyle style = short_format ? kCFDateFormatterShortStyle :  kCFDateFormatterLongStyle;
    QCFType<CFDateFormatterRef> myFormatter = CFDateFormatterCreate(kCFAllocatorDefault,
                                                                    mylocale,
                                                                    kCFDateFormatterNoStyle,
                                                                    style);
    return QString::fromCFString(CFDateFormatterCreateStringWithDate(0, myFormatter, myDate));
}

// Mac uses the Unicode CLDR format codes
// http://www.unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table
// See also qtbase/util/locale_database/dateconverter.py
// Makes the assumption that input formats are always well formed and consecutive letters
// never exceed the maximum for the format code.
static QVariant macToQtFormat(QStringView sys_fmt)
{
    QString result;
    int i = 0;

    while (i < sys_fmt.size()) {
        if (sys_fmt.at(i).unicode() == '\'') {
            QString text = qt_readEscapedFormatString(sys_fmt, &i);
            if (text == QLatin1String("'"))
                result += QLatin1String("''");
            else
                result += QLatin1Char('\'') + text + QLatin1Char('\'');
            continue;
        }

        QChar c = sys_fmt.at(i);
        qsizetype repeat = qt_repeatCount(sys_fmt.mid(i));

        switch (c.unicode()) {
            // Qt does not support the following options
            case 'G': // Era (1..5): 4 = long, 1..3 = short, 5 = narrow
            case 'Y': // Year of Week (1..n): 1..n = padded number
            case 'U': // Cyclic Year Name (1..5): 4 = long, 1..3 = short, 5 = narrow
            case 'Q': // Quarter (1..4): 4 = long, 3 = short, 1..2 = padded number
            case 'q': // Standalone Quarter (1..4): 4 = long, 3 = short, 1..2 = padded number
            case 'w': // Week of Year (1..2): 1..2 = padded number
            case 'W': // Week of Month (1): 1 = number
            case 'D': // Day of Year (1..3): 1..3 = padded number
            case 'F': // Day of Week in Month (1): 1 = number
            case 'g': // Modified Julian Day (1..n): 1..n = padded number
            case 'A': // Milliseconds in Day (1..n): 1..n = padded number
                break;

            case 'y': // Year (1..n): 2 = short year, 1 & 3..n = padded number
            case 'u': // Extended Year (1..n): 2 = short year, 1 & 3..n = padded number
                // Qt only supports long (4) or short (2) year, use long for all others
                if (repeat == 2)
                    result += QLatin1String("yy");
                else
                    result += QLatin1String("yyyy");
                break;
            case 'M': // Month (1..5): 4 = long, 3 = short, 1..2 = number, 5 = narrow
            case 'L': // Standalone Month (1..5): 4 = long, 3 = short, 1..2 = number, 5 = narrow
                // Qt only supports long, short and number, use short for narrow
                if (repeat == 5)
                    result += QLatin1String("MMM");
                else
                    result += QString(repeat, QLatin1Char('M'));
                break;
            case 'd': // Day of Month (1..2): 1..2 padded number
                result += QString(repeat, c);
                break;
            case 'E': // Day of Week (1..6): 4 = long, 1..3 = short, 5..6 = narrow
                // Qt only supports long, short and padded number, use short for narrow
                if (repeat == 4)
                    result += QLatin1String("dddd");
                else
                    result += QLatin1String("ddd");
                break;
            case 'e': // Local Day of Week (1..6): 4 = long, 3 = short, 5..6 = narrow, 1..2 padded number
            case 'c': // Standalone Local Day of Week (1..6): 4 = long, 3 = short, 5..6 = narrow, 1..2 padded number
                // Qt only supports long, short and padded number, use short for narrow
                if (repeat >= 5)
                    result += QLatin1String("ddd");
                else
                    result += QString(repeat, QLatin1Char('d'));
                break;
            case 'a': // AM/PM (1): 1 = short
                // Translate to Qt uppercase AM/PM
                result += QLatin1String("AP");
                break;
            case 'h': // Hour [1..12] (1..2): 1..2 = padded number
            case 'K': // Hour [0..11] (1..2): 1..2 = padded number
            case 'j': // Local Hour [12 or 24] (1..2): 1..2 = padded number
                // Qt h is local hour
                result += QString(repeat, QLatin1Char('h'));
                break;
            case 'H': // Hour [0..23] (1..2): 1..2 = padded number
            case 'k': // Hour [1..24] (1..2): 1..2 = padded number
                // Qt H is 0..23 hour
                result += QString(repeat, QLatin1Char('H'));
                break;
            case 'm': // Minutes (1..2): 1..2 = padded number
            case 's': // Seconds (1..2): 1..2 = padded number
                result += QString(repeat, c);
                break;
            case 'S': // Fractional second (1..n): 1..n = truncates to decimal places
                // Qt uses msecs either unpadded or padded to 3 places
                if (repeat < 3)
                    result += QLatin1Char('z');
                else
                    result += QLatin1String("zzz");
                break;
            case 'z': // Time Zone (1..4)
            case 'Z': // Time Zone (1..5)
            case 'O': // Time Zone (1, 4)
            case 'v': // Time Zone (1, 4)
            case 'V': // Time Zone (1..4)
            case 'X': // Time Zone (1..5)
            case 'x': // Time Zone (1..5)
                result += QLatin1Char('t');
                break;
            default:
                // a..z and A..Z are reserved for format codes, so any occurrence of these not
                // already processed are not known and so unsupported formats to be ignored.
                // All other chars are allowed as literals.
                if (c < QLatin1Char('A') || c > QLatin1Char('z') ||
                    (c > QLatin1Char('Z') && c < QLatin1Char('a'))) {
                    result += QString(repeat, c);
                }
                break;
        }

        i += repeat;
    }

    return !result.isEmpty() ? QVariant::fromValue(result) : QVariant();
}

static QVariant getMacDateFormat(CFDateFormatterStyle style)
{
    QCFType<CFLocaleRef> l = CFLocaleCopyCurrent();
    QCFType<CFDateFormatterRef> formatter = CFDateFormatterCreate(kCFAllocatorDefault,
                                                                  l, style, kCFDateFormatterNoStyle);
    return macToQtFormat(QString::fromCFString(CFDateFormatterGetFormat(formatter)));
}

static QVariant getMacTimeFormat(CFDateFormatterStyle style)
{
    QCFType<CFLocaleRef> l = CFLocaleCopyCurrent();
    QCFType<CFDateFormatterRef> formatter = CFDateFormatterCreate(kCFAllocatorDefault,
                                                                  l, kCFDateFormatterNoStyle, style);
    return macToQtFormat(QString::fromCFString(CFDateFormatterGetFormat(formatter)));
}

static QVariant getCFLocaleValue(CFStringRef key)
{
    QCFType<CFLocaleRef> locale = CFLocaleCopyCurrent();
    CFTypeRef value = CFLocaleGetValue(locale, key);
    if (!value)
        return QVariant();
    return QString::fromCFString(CFStringRef(static_cast<CFTypeRef>(value)));
}

static QVariant macMeasurementSystem()
{
    QCFType<CFLocaleRef> locale = CFLocaleCopyCurrent();
    CFStringRef system = static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleMeasurementSystem));
    if (QString::fromCFString(system) == QLatin1String("Metric")) {
        return QLocale::MetricSystem;
    } else {
        return QLocale::ImperialSystem;
    }
}


static quint8 macFirstDayOfWeek()
{
    QCFType<CFCalendarRef> calendar = CFCalendarCopyCurrent();
    quint8 day = static_cast<quint8>(CFCalendarGetFirstWeekday(calendar))-1;
    if (day == 0)
        day = 7;
    return day;
}

static QVariant macCurrencySymbol(QLocale::CurrencySymbolFormat format)
{
    QCFType<CFLocaleRef> locale = CFLocaleCopyCurrent();
    switch (format) {
    case QLocale::CurrencyIsoCode:
        return QString::fromCFString(static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleCurrencyCode)));
    case QLocale::CurrencySymbol:
        return QString::fromCFString(static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleCurrencySymbol)));
    case QLocale::CurrencyDisplayName: {
        CFStringRef code = static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleCurrencyCode));
        QCFType<CFStringRef> value = CFLocaleCopyDisplayNameForPropertyValue(locale, kCFLocaleCurrencyCode, code);
        return QString::fromCFString(value);
    }
    default:
        break;
    }
    return {};
}

static QVariant macZeroDigit()
{
    QCFType<CFLocaleRef> locale = CFLocaleCopyCurrent();
    QCFType<CFNumberFormatterRef> numberFormatter =
            CFNumberFormatterCreate(nullptr, locale, kCFNumberFormatterNoStyle);
    static const int zeroDigit = 0;
    QCFType<CFStringRef> value = CFNumberFormatterCreateStringWithValue(nullptr, numberFormatter,
                                                                        kCFNumberIntType, &zeroDigit);
    return QString::fromCFString(value);
}

#ifndef QT_NO_SYSTEMLOCALE
static QVariant macFormatCurrency(const QSystemLocale::CurrencyToStringArgument &arg)
{
    QCFType<CFNumberRef> value;
    switch (arg.value.metaType().id()) {
    case QMetaType::Int:
    case QMetaType::UInt: {
        int v = arg.value.toInt();
        value = CFNumberCreate(NULL, kCFNumberIntType, &v);
        break;
    }
    case QMetaType::Double: {
        double v = arg.value.toDouble();
        value = CFNumberCreate(NULL, kCFNumberDoubleType, &v);
        break;
    }
    case QMetaType::LongLong:
    case QMetaType::ULongLong: {
        qint64 v = arg.value.toLongLong();
        value = CFNumberCreate(NULL, kCFNumberLongLongType, &v);
        break;
    }
    default:
        return {};
    }

    QCFType<CFLocaleRef> locale = CFLocaleCopyCurrent();
    QCFType<CFNumberFormatterRef> currencyFormatter =
            CFNumberFormatterCreate(NULL, locale, kCFNumberFormatterCurrencyStyle);
    if (!arg.symbol.isEmpty()) {
        CFNumberFormatterSetProperty(currencyFormatter, kCFNumberFormatterCurrencySymbol,
                                     arg.symbol.toCFString());
    }
    QCFType<CFStringRef> result = CFNumberFormatterCreateStringWithNumber(NULL, currencyFormatter, value);
    return QString::fromCFString(result);
}

static QVariant macQuoteString(QSystemLocale::QueryType type, QStringView str)
{
    QString begin, end;
    QCFType<CFLocaleRef> locale = CFLocaleCopyCurrent();
    switch (type) {
    case QSystemLocale::StringToStandardQuotation:
        begin = QString::fromCFString(static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleQuotationBeginDelimiterKey)));
        end = QString::fromCFString(static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleQuotationEndDelimiterKey)));
        return QString(begin % str % end);
    case QSystemLocale::StringToAlternateQuotation:
        begin = QString::fromCFString(static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleAlternateQuotationBeginDelimiterKey)));
        end = QString::fromCFString(static_cast<CFStringRef>(CFLocaleGetValue(locale, kCFLocaleAlternateQuotationEndDelimiterKey)));
        return QString(begin % str % end);
     default:
        break;
    }
    return QVariant();
}
#endif //QT_NO_SYSTEMLOCALE

#ifndef QT_NO_SYSTEMLOCALE

QLocale QSystemLocale::fallbackLocale() const
{
    return QLocale(getMacLocaleName());
}

template <auto CodeToValueFunction>
static QVariant getLocaleValue(CFStringRef key)
{
    if (auto code = getCFLocaleValue(key); !code.isNull()) {
        // If an invalid locale is requested with -AppleLocale, the system APIs
        // will report invalid or empty locale values back to us, which codeToLanguage()
        // and friends will fail to parse, resulting in returning QLocale::Any{L/C/S}.
        // If this is the case, we fall down and return a null-variant, which
        // QLocale's updateSystemPrivate() will interpret to use fallback logic.
        if (auto value = CodeToValueFunction(code.toString()))
            return value;
    }
    return QVariant();
}

QVariant QSystemLocale::query(QueryType type, QVariant in) const
{
    QMacAutoReleasePool pool;
    switch(type) {
    case LanguageId:
        return getLocaleValue<QLocalePrivate::codeToLanguage>(kCFLocaleLanguageCode);
    case TerritoryId:
        return getLocaleValue<QLocalePrivate::codeToTerritory>(kCFLocaleCountryCode);
    case ScriptId:
        return getLocaleValue<QLocalePrivate::codeToScript>(kCFLocaleScriptCode);
    case DecimalPoint:
        return getCFLocaleValue(kCFLocaleDecimalSeparator);
    case GroupSeparator:
        return getCFLocaleValue(kCFLocaleGroupingSeparator);
    case DateFormatLong:
    case DateFormatShort:
        return getMacDateFormat(type == DateFormatShort
                                ? kCFDateFormatterShortStyle
                                : kCFDateFormatterLongStyle);
    case TimeFormatLong:
    case TimeFormatShort:
        return getMacTimeFormat(type == TimeFormatShort
                                ? kCFDateFormatterShortStyle
                                : kCFDateFormatterLongStyle);
    case DayNameLong:
    case DayNameShort:
    case DayNameNarrow:
    case StandaloneDayNameLong:
    case StandaloneDayNameShort:
    case StandaloneDayNameNarrow:
        return macDayName(in.toInt(), type);
    case MonthNameLong:
    case MonthNameShort:
    case MonthNameNarrow:
    case StandaloneMonthNameLong:
    case StandaloneMonthNameShort:
    case StandaloneMonthNameNarrow:
        return macMonthName(in.toInt(), type);
    case DateToStringShort:
    case DateToStringLong:
        return macDateToString(in.toDate(), (type == DateToStringShort));
    case TimeToStringShort:
    case TimeToStringLong:
        return macTimeToString(in.toTime(), (type == TimeToStringShort));

    case NegativeSign:
    case PositiveSign:
        break;
    case ZeroDigit:
        return macZeroDigit();

    case MeasurementSystem:
        return macMeasurementSystem();

    case AMText:
    case PMText: {
        QCFType<CFLocaleRef> locale = CFLocaleCopyCurrent();
        QCFType<CFDateFormatterRef> formatter = CFDateFormatterCreate(NULL, locale, kCFDateFormatterLongStyle, kCFDateFormatterLongStyle);
        QCFType<CFStringRef> value = static_cast<CFStringRef>(CFDateFormatterCopyProperty(formatter,
            (type == AMText ? kCFDateFormatterAMSymbol : kCFDateFormatterPMSymbol)));
        return QString::fromCFString(value);
    }
    case FirstDayOfWeek:
        return QVariant(macFirstDayOfWeek());
    case CurrencySymbol:
        return macCurrencySymbol(QLocale::CurrencySymbolFormat(in.toUInt()));
    case CurrencyToString:
        return macFormatCurrency(in.value<QSystemLocale::CurrencyToStringArgument>());
    case UILanguages: {
        QStringList result;
        QCFType<CFArrayRef> languages = CFLocaleCopyPreferredLanguages();
        const int cnt = CFArrayGetCount(languages);
        result.reserve(cnt);
        for (int i = 0; i < cnt; ++i) {
            const QString lang = QString::fromCFString(
                static_cast<CFStringRef>(CFArrayGetValueAtIndex(languages, i)));
            result.append(lang);
        }
        return QVariant(result);
    }
    case StringToStandardQuotation:
    case StringToAlternateQuotation:
        return macQuoteString(type, in.value<QStringView>());
    default:
        break;
    }
    return QVariant();
}

#endif // QT_NO_SYSTEMLOCALE

QT_END_NAMESPACE
