# Copyright (C) 2022 The Qt Company Ltd.
# SPDX-License-Identifier: LicenseRef-Qt-Commercial OR GPL-3.0-only WITH Qt-GPL-exception-1.0

find_package(PkgConfig QUIET)

pkg_check_modules(Mtdev mtdev IMPORTED_TARGET)

if (NOT TARGET PkgConfig::Mtdev)
    set(Mtdev_FOUND 0)
endif()
