# Copyright (C) 2022 The Qt Company Ltd.
# SPDX-License-Identifier: LicenseRef-Qt-Commercial OR GPL-3.0-only WITH Qt-GPL-exception-1.0

file(ARCHIVE_CREATE
    OUTPUT cmake_zstd.zstd
    PATHS "${CMAKE_CURRENT_LIST_FILE}"
    FORMAT raw
    COMPRESSION Zstd)
