// Copyright (C) 2019 The Qt Company Ltd.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

#include "qrhimetal_p_p.h"
#include <QtGui/private/qshader_p_p.h>
#include <QGuiApplication>
#include <QWindow>
#include <QUrl>
#include <QFile>
#include <QTemporaryFile>
#include <QFileInfo>
#include <qmath.h>
#include <QOperatingSystemVersion>

#include <QtCore/private/qcore_mac_p.h>

#ifdef Q_OS_MACOS
#include <AppKit/AppKit.h>
#else
#include <UIKit/UIKit.h>
#endif

#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>

QT_BEGIN_NAMESPACE

/*
    Metal backend. Double buffers and throttles to vsync. "Dynamic" buffers are
    Shared (host visible) and duplicated (to help having 2 frames in flight),
    "static" and "immutable" are Managed on macOS and Shared on iOS/tvOS.
    Textures are Private (device local) and a host visible staging buffer is
    used to upload data to them. Does not rely on strong objects refs from
    command buffers but does rely on the automatic resource tracking of the
    command encoders. Assumes that an autorelease pool (ideally per frame) is
    available on the thread on which QRhi is used.
*/

#if __has_feature(objc_arc)
#error ARC not supported
#endif

// Note: we expect everything here pass the Metal API validation when running
// in Debug mode in XCode (or with METAL_DEVICE_WRAPPER_TYPE=1). An exception
// is the nextDrawable Called Early blah blah warning, which is plain and
// simply false. This may not be present with newer XCode. There may also be
// warnings about threading (e.g. about accessing view.layer), those are
// expected for now.

/*!
    \class QRhiMetalInitParams
    \inmodule QtRhi
    \internal
    \brief Metal specific initialization parameters.

    A Metal-based QRhi needs no special parameters for initialization.

    \badcode
        QRhiMetalInitParams params;
        rhi = QRhi::create(QRhi::Metal, &params);
    \endcode

    \note Metal API validation cannot be enabled programmatically by the QRhi.
    Instead, either run the debug build of the application in XCode, by
    generating a \c{.xcodeproj} file via \c{cmake -G Xcode}, or set the
    environment variable \c{METAL_DEVICE_WRAPPER_TYPE=1}. The variable needs to
    be set early on in the environment, perferably before starting the process;
    attempting to set it at QRhi creation time is not functional in practice.
    (too late probably)

    \note QRhiSwapChain can only target QWindow instances that have their
    surface type set to QSurface::MetalSurface.

    \section2 Working with existing Metal devices

    When interoperating with another graphics engine, it may be necessary to
    get a QRhi instance that uses the same Metal device. This can be achieved
    by passing a pointer to a QRhiMetalNativeHandles to QRhi::create(). The
    device must be set to a non-null value then. Optionally, a command queue
    object can be specified as well.

    The QRhi does not take ownership of any of the external objects.
 */

/*!
    \class QRhiMetalNativeHandles
    \inmodule QtRhi
    \internal
    \brief Holds the Metal device used by the QRhi.
 */

/*!
    \class QRhiMetalCommandBufferNativeHandles
    \inmodule QtRhi
    \internal
    \brief Holds the MTLCommandBuffer and MTLRenderCommandEncoder objects that are backing a QRhiCommandBuffer.

    \note The command buffer object is only guaranteed to be valid while
    recording a frame, that is, between a \l{QRhi::beginFrame()}{beginFrame()}
    - \l{QRhi::endFrame()}{endFrame()} or
    \l{QRhi::beginOffscreenFrame()}{beginOffscreenFrame()} -
    \l{QRhi::endOffscreenFrame()}{endOffsrceenFrame()} pair.

    \note The command encoder is only valid while recording a pass, that is,
    between \l{QRhiCommandBuffer::beginPass()} -
    \l{QRhiCommandBuffer::endPass()}.
 */

struct QMetalShader
{
    id<MTLLibrary> lib = nil;
    id<MTLFunction> func = nil;
    std::array<uint, 3> localSize = {};
    uint outputVertexCount = 0;
    QShaderDescription desc;
    QShader::NativeResourceBindingMap nativeResourceBindingMap;
    QShader::NativeShaderInfo nativeShaderInfo;

    void destroy() {
        nativeResourceBindingMap.clear();
        [lib release];
        lib = nil;
        [func release];
        func = nil;
    }
};

struct QRhiMetalData
{
    QRhiMetalData(QRhiMetal *rhi) : q(rhi), ofr(rhi) { }

    QRhiMetal *q;
    id<MTLDevice> dev = nil;
    id<MTLCommandQueue> cmdQueue = nil;
    API_AVAILABLE(macosx(11.0), ios(14.0)) id<MTLBinaryArchive> binArch = nil;
    bool binArchWasEmpty = false;

    MTLRenderPassDescriptor *createDefaultRenderPass(bool hasDepthStencil,
                                                     const QColor &colorClearValue,
                                                     const QRhiDepthStencilClearValue &depthStencilClearValue,
                                                     int colorAttCount);
    id<MTLLibrary> createMetalLib(const QShader &shader, QShader::Variant shaderVariant,
                                  QString *error, QByteArray *entryPoint, QShaderKey *activeKey);
    id<MTLFunction> createMSLShaderFunction(id<MTLLibrary> lib, const QByteArray &entryPoint);
    bool setupBinaryArchive(NSURL *sourceFileUrl = nil);
    void addRenderPipelineToBinaryArchive(MTLRenderPipelineDescriptor *rpDesc);
    void trySeedingRenderPipelineFromBinaryArchive(MTLRenderPipelineDescriptor *rpDesc);
    void addComputePipelineToBinaryArchive(MTLComputePipelineDescriptor *cpDesc);
    void trySeedingComputePipelineFromBinaryArchive(MTLComputePipelineDescriptor *cpDesc);

    struct DeferredReleaseEntry {
        enum Type {
            Buffer,
            RenderBuffer,
            Texture,
            Sampler,
            StagingBuffer,
            GraphicsPipeline,
            ComputePipeline
        };
        Type type;
        int lastActiveFrameSlot; // -1 if not used otherwise 0..FRAMES_IN_FLIGHT-1
        union {
            struct {
                id<MTLBuffer> buffers[QMTL_FRAMES_IN_FLIGHT];
            } buffer;
            struct {
                id<MTLTexture> texture;
            } renderbuffer;
            struct {
                id<MTLTexture> texture;
                id<MTLBuffer> stagingBuffers[QMTL_FRAMES_IN_FLIGHT];
                id<MTLTexture> views[QRhi::MAX_MIP_LEVELS];
            } texture;
            struct {
                id<MTLSamplerState> samplerState;
            } sampler;
            struct {
                id<MTLBuffer> buffer;
            } stagingBuffer;
            struct {
                id<MTLRenderPipelineState> pipelineState;
                id<MTLDepthStencilState> depthStencilState;
                std::array<id<MTLComputePipelineState>, 3> tessVertexComputeState;
                id<MTLComputePipelineState> tessTessControlComputeState;
            } graphicsPipeline;
            struct {
                id<MTLComputePipelineState> pipelineState;
            } computePipeline;
        };
    };
    QVector<DeferredReleaseEntry> releaseQueue;

    struct OffscreenFrame {
        OffscreenFrame(QRhiImplementation *rhi) : cbWrapper(rhi) { }
        bool active = false;
        QMetalCommandBuffer cbWrapper;
    } ofr;

    struct TextureReadback {
        int activeFrameSlot = -1;
        QRhiReadbackDescription desc;
        QRhiReadbackResult *result;
        id<MTLBuffer> buf;
        quint32 bufSize;
        QSize pixelSize;
        QRhiTexture::Format format;
    };
    QVarLengthArray<TextureReadback, 2> activeTextureReadbacks;

    struct BufferReadback
    {
        int activeFrameSlot = -1;
        QRhiBufferReadbackResult *result;
        quint32 offset;
        quint32 readSize;
        id<MTLBuffer> buf;
    };

    QVarLengthArray<BufferReadback, 2> activeBufferReadbacks;

    MTLCaptureManager *captureMgr;
    id<MTLCaptureScope> captureScope = nil;

    static const int TEXBUF_ALIGN = 256; // probably not accurate

    QHash<QRhiShaderStage, QMetalShader> shaderCache;
};

Q_DECLARE_TYPEINFO(QRhiMetalData::DeferredReleaseEntry, Q_RELOCATABLE_TYPE);
Q_DECLARE_TYPEINFO(QRhiMetalData::TextureReadback, Q_RELOCATABLE_TYPE);

struct QMetalBufferData
{
    bool managed;
    bool slotted;
    id<MTLBuffer> buf[QMTL_FRAMES_IN_FLIGHT];
    struct BufferUpdate {
        quint32 offset;
        QRhiBufferData data;
    };
    QVarLengthArray<BufferUpdate, 16> pendingUpdates[QMTL_FRAMES_IN_FLIGHT];
};

struct QMetalRenderBufferData
{
    MTLPixelFormat format;
    id<MTLTexture> tex = nil;
};

struct QMetalTextureData
{
    QMetalTextureData(QMetalTexture *t) : q(t) { }

    QMetalTexture *q;
    MTLPixelFormat format;
    id<MTLTexture> tex = nil;
    id<MTLBuffer> stagingBuf[QMTL_FRAMES_IN_FLIGHT];
    bool owns = true;
    id<MTLTexture> perLevelViews[QRhi::MAX_MIP_LEVELS];

    id<MTLTexture> viewForLevel(int level);
};

struct QMetalSamplerData
{
    id<MTLSamplerState> samplerState = nil;
};

struct QMetalShaderResourceBindingsData {
    struct Stage {
        struct Buffer {
            int nativeBinding;
            id<MTLBuffer> mtlbuf;
            quint32 offset;
        };
        struct Texture {
            int nativeBinding;
            id<MTLTexture> mtltex;
        };
        struct Sampler {
            int nativeBinding;
            id<MTLSamplerState> mtlsampler;
        };
        QVarLengthArray<Buffer, 8> buffers;
        QVarLengthArray<Texture, 8> textures;
        QVarLengthArray<Sampler, 8> samplers;
        QRhiBatchedBindings<id<MTLBuffer> > bufferBatches;
        QRhiBatchedBindings<NSUInteger> bufferOffsetBatches;
        QRhiBatchedBindings<id<MTLTexture> > textureBatches;
        QRhiBatchedBindings<id<MTLSamplerState> > samplerBatches;
    } res[QRhiMetal::SUPPORTED_STAGES];
    enum { VERTEX = 0, FRAGMENT = 1, COMPUTE = 2 };
};

struct QMetalCommandBufferData
{
    id<MTLCommandBuffer> cb;
    id<MTLRenderCommandEncoder> currentRenderPassEncoder;
    id<MTLComputeCommandEncoder> currentComputePassEncoder;
    id<MTLComputeCommandEncoder> tessellationComputeEncoder;
    MTLRenderPassDescriptor *currentPassRpDesc;
    int currentFirstVertexBinding;
    QRhiBatchedBindings<id<MTLBuffer> > currentVertexInputsBuffers;
    QRhiBatchedBindings<NSUInteger> currentVertexInputOffsets;
    id<MTLDepthStencilState> currentDepthStencilState;
    QMetalShaderResourceBindingsData currentShaderResourceBindingState;
};

struct QMetalRenderTargetData
{
    QSize pixelSize;
    float dpr = 1;
    int sampleCount = 1;
    int colorAttCount = 0;
    int dsAttCount = 0;

    struct ColorAtt {
        bool needsDrawableForTex = false;
        id<MTLTexture> tex = nil;
        int arrayLayer = 0;
        int slice = 0;
        int level = 0;
        bool needsDrawableForResolveTex = false;
        id<MTLTexture> resolveTex = nil;
        int resolveLayer = 0;
        int resolveLevel = 0;
    };

    struct {
        ColorAtt colorAtt[QMetalRenderPassDescriptor::MAX_COLOR_ATTACHMENTS];
        id<MTLTexture> dsTex = nil;
        bool hasStencil = false;
        bool depthNeedsStore = false;
    } fb;

    QRhiRenderTargetAttachmentTracker::ResIdList currentResIdList;
};

struct QMetalGraphicsPipelineData
{
    QMetalGraphicsPipeline *q = nullptr;
    id<MTLRenderPipelineState> ps = nil;
    id<MTLDepthStencilState> ds = nil;
    MTLPrimitiveType primitiveType;
    MTLWinding winding;
    MTLCullMode cullMode;
    MTLTriangleFillMode triangleFillMode;
    float depthBias;
    float slopeScaledDepthBias;
    QMetalShader vs;
    QMetalShader fs;
    struct Tessellation {
        QMetalGraphicsPipelineData *q = nullptr;
        bool enabled = false;
        bool failed = false;
        uint inControlPointCount;
        uint outControlPointCount;
        QMetalShader compVs[3];
        std::array<id<MTLComputePipelineState>, 3> vertexComputeState = {};
        id<MTLComputePipelineState> tessControlComputeState = nil;
        QMetalShader compTesc;
        QMetalShader vertTese;
        quint32 vsCompOutputBufferSize(quint32 vertexOrIndexCount, quint32 instanceCount) const
        {
            // max vertex output components = resourceLimit(MaxVertexOutputs) * 4 = 60
            return vertexOrIndexCount * instanceCount * sizeof(float) * 60;
        }
        quint32 tescCompOutputBufferSize(quint32 patchCount) const
        {
            return outControlPointCount * patchCount * sizeof(float) * 60;
        }
        quint32 tescCompPatchOutputBufferSize(quint32 patchCount) const
        {
            // assume maxTessellationControlPerPatchOutputComponents is 128
            return patchCount * sizeof(float) * 128;
        }
        quint32 patchCountForDrawCall(quint32 vertexOrIndexCount, quint32 instanceCount) const
        {
            return ((vertexOrIndexCount + inControlPointCount - 1) / inControlPointCount) * instanceCount;
        }
        static int vsCompVariantToIndex(QShader::Variant vertexCompVariant);
        id<MTLComputePipelineState> vsCompPipeline(QRhiMetal *rhiD, QShader::Variant vertexCompVariant);
        id<MTLComputePipelineState> tescCompPipeline(QRhiMetal *rhiD);
        id<MTLRenderPipelineState> teseFragRenderPipeline(QRhiMetal *rhiD, QMetalGraphicsPipeline *pipeline);
        enum class WorkBufType {
            DeviceLocal,
            HostVisible
        };
        QMetalBuffer *acquireWorkBuffer(QRhiMetal *rhiD, quint32 size, WorkBufType type = WorkBufType::DeviceLocal);
        QVector<QMetalBuffer *> deviceLocalWorkBuffers;
        QVector<QMetalBuffer *> hostVisibleWorkBuffers;
    } tess;
    template<typename T> void setupVertexOrStageInputDescriptor(T *desc);
};

struct QMetalComputePipelineData
{
    id<MTLComputePipelineState> ps = nil;
    QMetalShader cs;
    MTLSize localSize;
};

struct QMetalSwapChainData
{
    CAMetalLayer *layer = nullptr;
    id<CAMetalDrawable> curDrawable = nil;
    dispatch_semaphore_t sem[QMTL_FRAMES_IN_FLIGHT];
    MTLRenderPassDescriptor *rp = nullptr;
    id<MTLTexture> msaaTex[QMTL_FRAMES_IN_FLIGHT];
    QRhiTexture::Format rhiColorFormat;
    MTLPixelFormat colorFormat;
};

QRhiMetal::QRhiMetal(QRhiMetalInitParams *params, QRhiMetalNativeHandles *importDevice)
{
    Q_UNUSED(params);

    d = new QRhiMetalData(this);

    importedDevice = importDevice != nullptr;
    if (importedDevice) {
        if (d->dev) {
            d->dev = (id<MTLDevice>) importDevice->dev;
            importedCmdQueue = importDevice->cmdQueue != nullptr;
            if (importedCmdQueue)
                d->cmdQueue = (id<MTLCommandQueue>) importDevice->cmdQueue;
        } else {
            qWarning("No MTLDevice given, cannot import");
            importedDevice = false;
        }
    }
}

QRhiMetal::~QRhiMetal()
{
    delete d;
}

template <class Int>
inline Int aligned(Int v, Int byteAlign)
{
    return (v + byteAlign - 1) & ~(byteAlign - 1);
}

bool QRhiMetal::probe(QRhiMetalInitParams *params)
{
    Q_UNUSED(params);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (dev) {
        [dev release];
        return true;
    }
    return false;
}

bool QRhiMetalData::setupBinaryArchive(NSURL *sourceFileUrl)
{
    if (@available(macOS 11.0, iOS 14.0, *)) {
        [binArch release];
        MTLBinaryArchiveDescriptor *binArchDesc = [MTLBinaryArchiveDescriptor new];
        binArchDesc.url = sourceFileUrl;
        NSError *err = nil;
        binArch = [dev newBinaryArchiveWithDescriptor: binArchDesc error: &err];
        [binArchDesc release];
        if (!binArch) {
            const QString msg = QString::fromNSString(err.localizedDescription);
            qWarning("newBinaryArchiveWithDescriptor failed: %s", qPrintable(msg));
            return false;
        }
        binArchWasEmpty = sourceFileUrl == nil;
        return true;
    }
    return false;
}

bool QRhiMetal::create(QRhi::Flags flags)
{
    rhiFlags = flags;

    if (importedDevice)
        [d->dev retain];
    else
        d->dev = MTLCreateSystemDefaultDevice();

    if (!d->dev) {
        qWarning("No MTLDevice");
        return false;
    }

    const QString deviceName = QString::fromNSString([d->dev name]);
    qCDebug(QRHI_LOG_INFO, "Metal device: %s", qPrintable(deviceName));
    driverInfoStruct.deviceName = deviceName.toUtf8();

    // deviceId and vendorId stay unset for now. Note that registryID is not
    // suitable as deviceId because it does not seem stable on macOS and can
    // apparently change when the system is rebooted.

#ifdef Q_OS_IOS
    driverInfoStruct.deviceType = QRhiDriverInfo::IntegratedDevice;
#else
    if (@available(macOS 10.15, *)) {
        const MTLDeviceLocation deviceLocation = [d->dev location];
        switch (deviceLocation) {
        case MTLDeviceLocationBuiltIn:
            driverInfoStruct.deviceType = QRhiDriverInfo::IntegratedDevice;
            break;
        case MTLDeviceLocationSlot:
            driverInfoStruct.deviceType = QRhiDriverInfo::DiscreteDevice;
            break;
        case MTLDeviceLocationExternal:
            driverInfoStruct.deviceType = QRhiDriverInfo::ExternalDevice;
            break;
        default:
            break;
        }
    }
#endif

    const QOperatingSystemVersion ver = QOperatingSystemVersion::current();
    osMajor = ver.majorVersion();
    osMinor = ver.minorVersion();

    if (importedCmdQueue)
        [d->cmdQueue retain];
    else
        d->cmdQueue = [d->dev newCommandQueue];

    d->captureMgr = [MTLCaptureManager sharedCaptureManager];
    // Have a custom capture scope as well which then shows up in XCode as
    // an option when capturing, and becomes especially useful when having
    // multiple windows with multiple QRhis.
    d->captureScope = [d->captureMgr newCaptureScopeWithCommandQueue: d->cmdQueue];
    const QString label = QString::asprintf("Qt capture scope for QRhi %p", this);
    d->captureScope.label = label.toNSString();

#if defined(Q_OS_MACOS)
    caps.maxTextureSize = 16384;
    caps.baseVertexAndInstance = true;
    if (@available(macOS 10.15, *))
        caps.isAppleGPU = [d->dev supportsFamily:MTLGPUFamilyApple7];
    caps.maxThreadGroupSize = 1024;
#elif defined(Q_OS_TVOS)
    if ([d->dev supportsFeatureSet: MTLFeatureSet(30003)]) // MTLFeatureSet_tvOS_GPUFamily2_v1
        caps.maxTextureSize = 16384;
    else
        caps.maxTextureSize = 8192;
    caps.baseVertexAndInstance = false;
    caps.isAppleGPU = true;
#elif defined(Q_OS_IOS)
    // welcome to feature set hell
    if ([d->dev supportsFeatureSet: MTLFeatureSet(16)] // MTLFeatureSet_iOS_GPUFamily5_v1
            || [d->dev supportsFeatureSet: MTLFeatureSet(11)] // MTLFeatureSet_iOS_GPUFamily4_v1
            || [d->dev supportsFeatureSet: MTLFeatureSet(4)]) // MTLFeatureSet_iOS_GPUFamily3_v1
    {
        caps.maxTextureSize = 16384;
        caps.baseVertexAndInstance = true;
    } else if ([d->dev supportsFeatureSet: MTLFeatureSet(3)] // MTLFeatureSet_iOS_GPUFamily2_v2
            || [d->dev supportsFeatureSet: MTLFeatureSet(2)]) // MTLFeatureSet_iOS_GPUFamily1_v2
    {
        caps.maxTextureSize = 8192;
        caps.baseVertexAndInstance = false;
    } else {
        caps.maxTextureSize = 4096;
        caps.baseVertexAndInstance = false;
    }
    caps.isAppleGPU = true;
    if (@available(iOS 13, *)) {
        if ([d->dev supportsFamily:MTLGPUFamilyApple4])
            caps.maxThreadGroupSize = 1024;
    }
#endif

    caps.supportedSampleCounts = { 1 };
    for (int sampleCount : { 2, 4, 8 }) {
        if ([d->dev supportsTextureSampleCount: sampleCount])
            caps.supportedSampleCounts.append(sampleCount);
    }

    if (rhiFlags.testFlag(QRhi::EnablePipelineCacheDataSave))
        d->setupBinaryArchive();

    nativeHandlesStruct.dev = (MTLDevice *) d->dev;
    nativeHandlesStruct.cmdQueue = (MTLCommandQueue *) d->cmdQueue;

    return true;
}

void QRhiMetal::destroy()
{
    executeDeferredReleases(true);
    finishActiveReadbacks(true);

    for (QMetalShader &s : d->shaderCache)
        s.destroy();
    d->shaderCache.clear();

    [d->captureScope release];
    d->captureScope = nil;

    if (@available(macOS 11.0, iOS 14.0, *)) {
        [d->binArch release];
        d->binArch = nil;
    }

    [d->cmdQueue release];
    if (!importedCmdQueue)
        d->cmdQueue = nil;

    [d->dev release];
    if (!importedDevice)
        d->dev = nil;
}

QVector<int> QRhiMetal::supportedSampleCounts() const
{
    return caps.supportedSampleCounts;
}

int QRhiMetal::effectiveSampleCount(int sampleCount) const
{
    // Stay compatible with QSurfaceFormat and friends where samples == 0 means the same as 1.
    const int s = qBound(1, sampleCount, 64);
    if (!supportedSampleCounts().contains(s)) {
        qWarning("Attempted to set unsupported sample count %d", sampleCount);
        return 1;
    }
    return s;
}

QRhiSwapChain *QRhiMetal::createSwapChain()
{
    return new QMetalSwapChain(this);
}

QRhiBuffer *QRhiMetal::createBuffer(QRhiBuffer::Type type, QRhiBuffer::UsageFlags usage, quint32 size)
{
    return new QMetalBuffer(this, type, usage, size);
}

int QRhiMetal::ubufAlignment() const
{
    return 256;
}

bool QRhiMetal::isYUpInFramebuffer() const
{
    return false;
}

bool QRhiMetal::isYUpInNDC() const
{
    return true;
}

bool QRhiMetal::isClipDepthZeroToOne() const
{
    return true;
}

QMatrix4x4 QRhiMetal::clipSpaceCorrMatrix() const
{
    // depth range 0..1
    static QMatrix4x4 m;
    if (m.isIdentity()) {
        // NB the ctor takes row-major
        m = QMatrix4x4(1.0f, 0.0f, 0.0f, 0.0f,
                       0.0f, 1.0f, 0.0f, 0.0f,
                       0.0f, 0.0f, 0.5f, 0.5f,
                       0.0f, 0.0f, 0.0f, 1.0f);
    }
    return m;
}

bool QRhiMetal::isTextureFormatSupported(QRhiTexture::Format format, QRhiTexture::Flags flags) const
{
    Q_UNUSED(flags);

    bool supportsFamilyMac2 = false; // needed for BC* formats
    bool supportsFamilyApple3 = false;

#ifdef Q_OS_MACOS
    supportsFamilyMac2 = true;
    if (caps.isAppleGPU)
        supportsFamilyApple3 = true;
#else
    supportsFamilyApple3 = true;
#endif

    // BC5 is not available for any Apple hardare
    if (format == QRhiTexture::BC5)
        return false;

    if (!supportsFamilyApple3) {
        if (format >= QRhiTexture::ETC2_RGB8 && format <= QRhiTexture::ETC2_RGBA8)
            return false;
        if (format >= QRhiTexture::ASTC_4x4 && format <= QRhiTexture::ASTC_12x12)
            return false;
    }

    if (!supportsFamilyMac2)
        if (format >= QRhiTexture::BC1 && format <= QRhiTexture::BC7)
            return false;

    return true;
}

bool QRhiMetal::isFeatureSupported(QRhi::Feature feature) const
{
    switch (feature) {
    case QRhi::MultisampleTexture:
        return true;
    case QRhi::MultisampleRenderBuffer:
        return true;
    case QRhi::DebugMarkers:
        return true;
    case QRhi::Timestamps:
        return false;
    case QRhi::Instancing:
        return true;
    case QRhi::CustomInstanceStepRate:
        return true;
    case QRhi::PrimitiveRestart:
        return true;
    case QRhi::NonDynamicUniformBuffers:
        return true;
    case QRhi::NonFourAlignedEffectiveIndexBufferOffset:
        return false;
    case QRhi::NPOTTextureRepeat:
        return true;
    case QRhi::RedOrAlpha8IsRed:
        return true;
    case QRhi::ElementIndexUint:
        return true;
    case QRhi::Compute:
        return true;
    case QRhi::WideLines:
        return false;
    case QRhi::VertexShaderPointSize:
        return true;
    case QRhi::BaseVertex:
        return caps.baseVertexAndInstance;
    case QRhi::BaseInstance:
        return caps.baseVertexAndInstance;
    case QRhi::TriangleFanTopology:
        return false;
    case QRhi::ReadBackNonUniformBuffer:
        return true;
    case QRhi::ReadBackNonBaseMipLevel:
        return true;
    case QRhi::TexelFetch:
        return true;
    case QRhi::RenderToNonBaseMipLevel:
        return true;
    case QRhi::IntAttributes:
        return true;
    case QRhi::ScreenSpaceDerivatives:
        return true;
    case QRhi::ReadBackAnyTextureFormat:
        return true;
    case QRhi::PipelineCacheDataLoadSave:
    {
        if (@available(macOS 11.0, iOS 14.0, *))
            return true;
        else
            return false;
    }
    case QRhi::ImageDataStride:
        return true;
    case QRhi::RenderBufferImport:
        return false;
    case QRhi::ThreeDimensionalTextures:
        return true;
    case QRhi::RenderTo3DTextureSlice:
        return true;
    case QRhi::TextureArrays:
        return true;
    case QRhi::Tessellation:
        return true;
    case QRhi::GeometryShader:
        return false;
    case QRhi::TextureArrayRange:
        return false;
    case QRhi::NonFillPolygonMode:
        return true;
    case QRhi::OneDimensionalTextures:
        return true;
    case QRhi::OneDimensionalTextureMipmaps:
        return false;
    default:
        Q_UNREACHABLE();
        return false;
    }
}

int QRhiMetal::resourceLimit(QRhi::ResourceLimit limit) const
{
    switch (limit) {
    case QRhi::TextureSizeMin:
        return 1;
    case QRhi::TextureSizeMax:
        return caps.maxTextureSize;
    case QRhi::MaxColorAttachments:
        return 8;
    case QRhi::FramesInFlight:
        return QMTL_FRAMES_IN_FLIGHT;
    case QRhi::MaxAsyncReadbackFrames:
        return QMTL_FRAMES_IN_FLIGHT;
    case QRhi::MaxThreadGroupsPerDimension:
        return 65535;
    case QRhi::MaxThreadsPerThreadGroup:
        Q_FALLTHROUGH();
    case QRhi::MaxThreadGroupX:
        Q_FALLTHROUGH();
    case QRhi::MaxThreadGroupY:
        Q_FALLTHROUGH();
    case QRhi::MaxThreadGroupZ:
        return caps.maxThreadGroupSize;
    case QRhi::TextureArraySizeMax:
        return 2048;
    case QRhi::MaxUniformBufferRange:
        return 65536;
    case QRhi::MaxVertexInputs:
        return 31;
    case QRhi::MaxVertexOutputs:
        return 15; // use the minimum from MTLGPUFamily1/2/3
    default:
        Q_UNREACHABLE();
        return 0;
    }
}

const QRhiNativeHandles *QRhiMetal::nativeHandles()
{
    return &nativeHandlesStruct;
}

QRhiDriverInfo QRhiMetal::driverInfo() const
{
    return driverInfoStruct;
}

QRhiStats QRhiMetal::statistics()
{
    QRhiStats result;
    result.totalPipelineCreationTime = totalPipelineCreationTime();
    return result;
}

bool QRhiMetal::makeThreadLocalNativeContextCurrent()
{
    // not applicable
    return false;
}

void QRhiMetal::releaseCachedResources()
{
    for (QMetalShader &s : d->shaderCache)
        s.destroy();

    d->shaderCache.clear();
}

bool QRhiMetal::isDeviceLost() const
{
    return false;
}

struct QMetalPipelineCacheDataHeader
{
    quint32 rhiId;
    quint32 arch;
    quint32 dataSize;
    quint32 osMajor;
    quint32 osMinor;
    char driver[236];
};

QByteArray QRhiMetal::pipelineCacheData()
{
    Q_STATIC_ASSERT(sizeof(QMetalPipelineCacheDataHeader) == 256);
    QByteArray data;
    if (@available(macOS 11.0, iOS 14.0, *)) {
        if (!d->binArch || !rhiFlags.testFlag(QRhi::EnablePipelineCacheDataSave))
            return data;

        QTemporaryFile tmp;
        if (!tmp.open()) {
            qWarning("pipelineCacheData: Failed to create temporary file for Metal");
            return data;
        }
        tmp.close(); // the file exists until the tmp dtor runs

        const QString fn = QFileInfo(tmp.fileName()).absoluteFilePath();
        NSURL *url = QUrl::fromLocalFile(fn).toNSURL();
        NSError *err = nil;
        if (![d->binArch serializeToURL: url error: &err]) {
            const QString msg = QString::fromNSString(err.localizedDescription);
            qWarning("Failed to serialize MTLBinaryArchive: %s", qPrintable(msg));
            return data;
        }

        QFile f(fn);
        if (!f.open(QIODevice::ReadOnly)) {
            qWarning("pipelineCacheData: Failed to reopen temporary file");
            return data;
        }
        const QByteArray blob = f.readAll();
        f.close();

        const size_t headerSize = sizeof(QMetalPipelineCacheDataHeader);
        const quint32 dataSize = quint32(blob.size());

        data.resize(headerSize + dataSize);

        QMetalPipelineCacheDataHeader header = {};
        header.rhiId = pipelineCacheRhiId();
        header.arch = quint32(sizeof(void*));
        header.dataSize = quint32(dataSize);
        header.osMajor = osMajor;
        header.osMinor = osMinor;
        const size_t driverStrLen = qMin(sizeof(header.driver) - 1, size_t(driverInfoStruct.deviceName.length()));
        if (driverStrLen)
            memcpy(header.driver, driverInfoStruct.deviceName.constData(), driverStrLen);
        header.driver[driverStrLen] = '\0';

        memcpy(data.data(), &header, headerSize);
        memcpy(data.data() + headerSize, blob.constData(), dataSize);
    }
    return data;
}

void QRhiMetal::setPipelineCacheData(const QByteArray &data)
{
    if (data.isEmpty())
        return;

    const size_t headerSize = sizeof(QMetalPipelineCacheDataHeader);
    if (data.size() < qsizetype(headerSize)) {
        qWarning("setPipelineCacheData: Invalid blob size (header incomplete)");
        return;
    }

    const size_t dataOffset = headerSize;
    QMetalPipelineCacheDataHeader header;
    memcpy(&header, data.constData(), headerSize);

    const quint32 rhiId = pipelineCacheRhiId();
    if (header.rhiId != rhiId) {
        qWarning("setPipelineCacheData: The data is for a different QRhi version or backend (%u, %u)",
                 rhiId, header.rhiId);
        return;
    }

    const quint32 arch = quint32(sizeof(void*));
    if (header.arch != arch) {
        qWarning("setPipelineCacheData: Architecture does not match (%u, %u)",
                 arch, header.arch);
        return;
    }

    if (header.osMajor != osMajor || header.osMinor != osMinor) {
        qWarning("setPipelineCacheData: OS version does not match (%u.%u, %u.%u)",
                 osMajor, osMinor, header.osMajor, header.osMinor);
        return;
    }

    const size_t driverStrLen = qMin(sizeof(header.driver) - 1, size_t(driverInfoStruct.deviceName.length()));
    if (strncmp(header.driver, driverInfoStruct.deviceName.constData(), driverStrLen)) {
        qWarning("setPipelineCacheData: Metal device name does not match");
        return;
    }

    if (data.size() < qsizetype(dataOffset + header.dataSize)) {
        qWarning("setPipelineCacheData: Invalid blob size (data incomplete)");
        return;
    }

    if (@available(macOS 11.0, iOS 14.0, *)) {
        const char *p = data.constData() + dataOffset;

        QTemporaryFile tmp;
        if (!tmp.open()) {
            qWarning("pipelineCacheData: Failed to create temporary file for Metal");
            return;
        }
        tmp.write(p, header.dataSize);
        tmp.close(); // the file exists until the tmp dtor runs

        const QString fn = QFileInfo(tmp.fileName()).absoluteFilePath();
        NSURL *url = QUrl::fromLocalFile(fn).toNSURL();
        if (d->setupBinaryArchive(url))
            qCDebug(QRHI_LOG_INFO, "Created MTLBinaryArchive with initial data of %u bytes", header.dataSize);
    }
}

QRhiRenderBuffer *QRhiMetal::createRenderBuffer(QRhiRenderBuffer::Type type, const QSize &pixelSize,
                                                int sampleCount, QRhiRenderBuffer::Flags flags,
                                                QRhiTexture::Format backingFormatHint)
{
    return new QMetalRenderBuffer(this, type, pixelSize, sampleCount, flags, backingFormatHint);
}

QRhiTexture *QRhiMetal::createTexture(QRhiTexture::Format format,
                                      const QSize &pixelSize, int depth, int arraySize,
                                      int sampleCount, QRhiTexture::Flags flags)
{
    return new QMetalTexture(this, format, pixelSize, depth, arraySize, sampleCount, flags);
}

QRhiSampler *QRhiMetal::createSampler(QRhiSampler::Filter magFilter, QRhiSampler::Filter minFilter,
                                      QRhiSampler::Filter mipmapMode,
                                      QRhiSampler::AddressMode u, QRhiSampler::AddressMode v, QRhiSampler::AddressMode w)
{
    return new QMetalSampler(this, magFilter, minFilter, mipmapMode, u, v, w);
}

QRhiTextureRenderTarget *QRhiMetal::createTextureRenderTarget(const QRhiTextureRenderTargetDescription &desc,
                                                              QRhiTextureRenderTarget::Flags flags)
{
    return new QMetalTextureRenderTarget(this, desc, flags);
}

QRhiGraphicsPipeline *QRhiMetal::createGraphicsPipeline()
{
    return new QMetalGraphicsPipeline(this);
}

QRhiComputePipeline *QRhiMetal::createComputePipeline()
{
    return new QMetalComputePipeline(this);
}

QRhiShaderResourceBindings *QRhiMetal::createShaderResourceBindings()
{
    return new QMetalShaderResourceBindings(this);
}

enum class BindingType {
    Buffer,
    Texture,
    Sampler
};

static inline int mapBinding(int binding,
                             int stageIndex,
                             const QShader::NativeResourceBindingMap *nativeResourceBindingMaps[],
                             BindingType type)
{
    const QShader::NativeResourceBindingMap *map = nativeResourceBindingMaps[stageIndex];
    if (!map || map->isEmpty())
        return binding; // old QShader versions do not have this map, assume 1:1 mapping then

    auto it = map->constFind(binding);
    if (it != map->cend())
        return type == BindingType::Sampler ? it->second : it->first; // may be -1, if the resource is inactive

    // Hitting this path is normal too. It is not given that the resource (for
    // example, a uniform block) is present in the shaders for all the stages
    // specified by the visibility mask in the QRhiShaderResourceBinding.
    return -1;
}

static inline void bindStageBuffers(QMetalCommandBuffer *cbD,
                                    int stage,
                                    const QRhiBatchedBindings<id<MTLBuffer>>::Batch &bufferBatch,
                                    const QRhiBatchedBindings<NSUInteger>::Batch &offsetBatch)
{
    switch (stage) {
    case QMetalShaderResourceBindingsData::VERTEX:
        [cbD->d->currentRenderPassEncoder setVertexBuffers: bufferBatch.resources.constData()
          offsets: offsetBatch.resources.constData()
          withRange: NSMakeRange(bufferBatch.startBinding, NSUInteger(bufferBatch.resources.count()))];
        break;
    case QMetalShaderResourceBindingsData::FRAGMENT:
        [cbD->d->currentRenderPassEncoder setFragmentBuffers: bufferBatch.resources.constData()
          offsets: offsetBatch.resources.constData()
          withRange: NSMakeRange(bufferBatch.startBinding, NSUInteger(bufferBatch.resources.count()))];
        break;
    case QMetalShaderResourceBindingsData::COMPUTE:
        [cbD->d->currentComputePassEncoder setBuffers: bufferBatch.resources.constData()
          offsets: offsetBatch.resources.constData()
          withRange: NSMakeRange(bufferBatch.startBinding, NSUInteger(bufferBatch.resources.count()))];
        break;
    default:
        Q_UNREACHABLE();
        break;
    }
}

static inline void bindStageTextures(QMetalCommandBuffer *cbD,
                                     int stage,
                                     const QRhiBatchedBindings<id<MTLTexture>>::Batch &textureBatch)
{
    switch (stage) {
    case QMetalShaderResourceBindingsData::VERTEX:
        [cbD->d->currentRenderPassEncoder setVertexTextures: textureBatch.resources.constData()
          withRange: NSMakeRange(textureBatch.startBinding, NSUInteger(textureBatch.resources.count()))];
        break;
    case QMetalShaderResourceBindingsData::FRAGMENT:
        [cbD->d->currentRenderPassEncoder setFragmentTextures: textureBatch.resources.constData()
          withRange: NSMakeRange(textureBatch.startBinding, NSUInteger(textureBatch.resources.count()))];
        break;
    case QMetalShaderResourceBindingsData::COMPUTE:
        [cbD->d->currentComputePassEncoder setTextures: textureBatch.resources.constData()
          withRange: NSMakeRange(textureBatch.startBinding, NSUInteger(textureBatch.resources.count()))];
        break;
    default:
        Q_UNREACHABLE();
        break;
    }
}

static inline void bindStageSamplers(QMetalCommandBuffer *cbD,
                                     int encoderStage,
                                     const QRhiBatchedBindings<id<MTLSamplerState>>::Batch &samplerBatch)
{
    switch (encoderStage) {
    case QMetalShaderResourceBindingsData::VERTEX:
        [cbD->d->currentRenderPassEncoder setVertexSamplerStates: samplerBatch.resources.constData()
          withRange: NSMakeRange(samplerBatch.startBinding, NSUInteger(samplerBatch.resources.count()))];
        break;
    case QMetalShaderResourceBindingsData::FRAGMENT:
        [cbD->d->currentRenderPassEncoder setFragmentSamplerStates: samplerBatch.resources.constData()
          withRange: NSMakeRange(samplerBatch.startBinding, NSUInteger(samplerBatch.resources.count()))];
        break;
    case QMetalShaderResourceBindingsData::COMPUTE:
        [cbD->d->currentComputePassEncoder setSamplerStates: samplerBatch.resources.constData()
          withRange: NSMakeRange(samplerBatch.startBinding, NSUInteger(samplerBatch.resources.count()))];
        break;
    default:
        Q_UNREACHABLE();
        break;
    }
}

// Helper that is not used during the common vertex+fragment and compute
// pipelines, but is necessary when tessellation is involved and so the
// graphics pipeline is under the hood a combination of multiple compute and
// render pipelines. We need to be able to set the buffers, textures, samplers
// when a switching between render and compute encoders.
static inline void rebindShaderResources(QMetalCommandBuffer *cbD, int resourceStage, int encoderStage,
                                         const QMetalShaderResourceBindingsData *customBindingState = nullptr)
{
    const QMetalShaderResourceBindingsData *bindingData = customBindingState ? customBindingState : &cbD->d->currentShaderResourceBindingState;

    for (int i = 0, ie = bindingData->res[resourceStage].bufferBatches.batches.count(); i != ie; ++i) {
        const auto &bufferBatch(bindingData->res[resourceStage].bufferBatches.batches[i]);
        const auto &offsetBatch(bindingData->res[resourceStage].bufferOffsetBatches.batches[i]);
        bindStageBuffers(cbD, encoderStage, bufferBatch, offsetBatch);
    }

    for (int i = 0, ie = bindingData->res[resourceStage].textureBatches.batches.count(); i != ie; ++i) {
        const auto &batch(bindingData->res[resourceStage].textureBatches.batches[i]);
        bindStageTextures(cbD, encoderStage, batch);
    }

    for (int i = 0, ie = bindingData->res[resourceStage].samplerBatches.batches.count(); i != ie; ++i) {
        const auto &batch(bindingData->res[resourceStage].samplerBatches.batches[i]);
        bindStageSamplers(cbD, encoderStage, batch);
    }
}

// Resources marked for the tess.control and/or eval. stages are treated as if
// they were for the vertex stage. For tess.eval. this is trivial because
// that's translated to a Metal a vertex function, but tess.control (and the
// GLSL vertex) shader becomes compute. Yet dumping them under the vertex
// category still works, because rebindShaderResources(VERTEX, COMPUTE) can
// then be used to set them active on the compute encoder.
static inline bool isVertexishResource(QRhiShaderResourceBinding::StageFlags stages)
{
    return stages.testAnyFlags(QRhiShaderResourceBinding::VertexStage
                               | QRhiShaderResourceBinding::TessellationControlStage
                               | QRhiShaderResourceBinding::TessellationEvaluationStage);
}

void QRhiMetal::enqueueShaderResourceBindings(QMetalShaderResourceBindings *srbD,
                                              QMetalCommandBuffer *cbD,
                                              int dynamicOffsetCount,
                                              const QRhiCommandBuffer::DynamicOffset *dynamicOffsets,
                                              bool offsetOnlyChange,
                                              const QShader::NativeResourceBindingMap *nativeResourceBindingMaps[SUPPORTED_STAGES])
{
    QMetalShaderResourceBindingsData bindingData;

    for (const QRhiShaderResourceBinding &binding : std::as_const(srbD->sortedBindings)) {
        const QRhiShaderResourceBinding::Data *b = binding.data();
        switch (b->type) {
        case QRhiShaderResourceBinding::UniformBuffer:
        {
            QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, b->u.ubuf.buf);
            id<MTLBuffer> mtlbuf = bufD->d->buf[bufD->d->slotted ? currentFrameSlot : 0];
            quint32 offset = b->u.ubuf.offset;
            for (int i = 0; i < dynamicOffsetCount; ++i) {
                const QRhiCommandBuffer::DynamicOffset &dynOfs(dynamicOffsets[i]);
                if (dynOfs.first == b->binding) {
                    offset = dynOfs.second;
                    break;
                }
            }
            if (isVertexishResource(b->stage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::VERTEX, nativeResourceBindingMaps, BindingType::Buffer);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::VERTEX].buffers.append({ nativeBinding, mtlbuf, offset });
            }
            if (b->stage.testFlag(QRhiShaderResourceBinding::FragmentStage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::FRAGMENT, nativeResourceBindingMaps, BindingType::Buffer);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::FRAGMENT].buffers.append({ nativeBinding, mtlbuf, offset });
            }
            if (b->stage.testFlag(QRhiShaderResourceBinding::ComputeStage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::COMPUTE, nativeResourceBindingMaps, BindingType::Buffer);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::COMPUTE].buffers.append({ nativeBinding, mtlbuf, offset });
            }
        }
            break;
        case QRhiShaderResourceBinding::SampledTexture:
        case QRhiShaderResourceBinding::Texture:
        case QRhiShaderResourceBinding::Sampler:
        {
            const QRhiShaderResourceBinding::Data::TextureAndOrSamplerData *data = &b->u.stex;
            for (int elem = 0; elem < data->count; ++elem) {
                QMetalTexture *texD = QRHI_RES(QMetalTexture, b->u.stex.texSamplers[elem].tex);
                QMetalSampler *samplerD = QRHI_RES(QMetalSampler, b->u.stex.texSamplers[elem].sampler);
                if (isVertexishResource(b->stage)) {
                    // Must handle all three cases (combined, separate, separate):
                    //   first = texture binding, second = sampler binding
                    //   first = texture binding
                    //   first = sampler binding (i.e. BindingType::Texture...)
                    const int textureBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::VERTEX, nativeResourceBindingMaps, BindingType::Texture);
                    const int samplerBinding = texD && samplerD ? mapBinding(b->binding, QMetalShaderResourceBindingsData::VERTEX, nativeResourceBindingMaps, BindingType::Sampler)
                                                                : (samplerD ? mapBinding(b->binding, QMetalShaderResourceBindingsData::VERTEX, nativeResourceBindingMaps, BindingType::Texture) : -1);
                    if (textureBinding >= 0 && texD)
                        bindingData.res[QMetalShaderResourceBindingsData::VERTEX].textures.append({ textureBinding + elem, texD->d->tex });
                    if (samplerBinding >= 0)
                        bindingData.res[QMetalShaderResourceBindingsData::VERTEX].samplers.append({ samplerBinding + elem, samplerD->d->samplerState });
                }
                if (b->stage.testFlag(QRhiShaderResourceBinding::FragmentStage)) {
                    const int textureBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::FRAGMENT, nativeResourceBindingMaps, BindingType::Texture);
                    const int samplerBinding = texD && samplerD ? mapBinding(b->binding, QMetalShaderResourceBindingsData::FRAGMENT, nativeResourceBindingMaps, BindingType::Sampler)
                                                                : (samplerD ? mapBinding(b->binding, QMetalShaderResourceBindingsData::FRAGMENT, nativeResourceBindingMaps, BindingType::Texture) : -1);
                    if (textureBinding >= 0 && texD)
                        bindingData.res[QMetalShaderResourceBindingsData::FRAGMENT].textures.append({ textureBinding + elem, texD->d->tex });
                    if (samplerBinding >= 0)
                        bindingData.res[QMetalShaderResourceBindingsData::FRAGMENT].samplers.append({ samplerBinding + elem, samplerD->d->samplerState });
                }
                if (b->stage.testFlag(QRhiShaderResourceBinding::ComputeStage)) {
                    const int textureBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::COMPUTE, nativeResourceBindingMaps, BindingType::Texture);
                    const int samplerBinding = texD && samplerD ? mapBinding(b->binding, QMetalShaderResourceBindingsData::COMPUTE, nativeResourceBindingMaps, BindingType::Sampler)
                                                                : (samplerD ? mapBinding(b->binding, QMetalShaderResourceBindingsData::COMPUTE, nativeResourceBindingMaps, BindingType::Texture) : -1);
                    if (textureBinding >= 0 && texD)
                        bindingData.res[QMetalShaderResourceBindingsData::COMPUTE].textures.append({ textureBinding + elem, texD->d->tex });
                    if (samplerBinding >= 0)
                        bindingData.res[QMetalShaderResourceBindingsData::COMPUTE].samplers.append({ samplerBinding + elem, samplerD->d->samplerState });
                }
            }
        }
            break;
        case QRhiShaderResourceBinding::ImageLoad:
        case QRhiShaderResourceBinding::ImageStore:
        case QRhiShaderResourceBinding::ImageLoadStore:
        {
            QMetalTexture *texD = QRHI_RES(QMetalTexture, b->u.simage.tex);
            id<MTLTexture> t = texD->d->viewForLevel(b->u.simage.level);
            if (isVertexishResource(b->stage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::VERTEX, nativeResourceBindingMaps, BindingType::Texture);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::VERTEX].textures.append({ nativeBinding, t });
            }
            if (b->stage.testFlag(QRhiShaderResourceBinding::FragmentStage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::FRAGMENT, nativeResourceBindingMaps, BindingType::Texture);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::FRAGMENT].textures.append({ nativeBinding, t });
            }
            if (b->stage.testFlag(QRhiShaderResourceBinding::ComputeStage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::COMPUTE, nativeResourceBindingMaps, BindingType::Texture);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::COMPUTE].textures.append({ nativeBinding, t });
            }
        }
            break;
        case QRhiShaderResourceBinding::BufferLoad:
        case QRhiShaderResourceBinding::BufferStore:
        case QRhiShaderResourceBinding::BufferLoadStore:
        {
            QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, b->u.sbuf.buf);
            id<MTLBuffer> mtlbuf = bufD->d->buf[0];
            quint32 offset = b->u.sbuf.offset;
            if (isVertexishResource(b->stage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::VERTEX, nativeResourceBindingMaps, BindingType::Buffer);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::VERTEX].buffers.append({ nativeBinding, mtlbuf, offset });
            }
            if (b->stage.testFlag(QRhiShaderResourceBinding::FragmentStage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::FRAGMENT, nativeResourceBindingMaps, BindingType::Buffer);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::FRAGMENT].buffers.append({ nativeBinding, mtlbuf, offset });
            }
            if (b->stage.testFlag(QRhiShaderResourceBinding::ComputeStage)) {
                const int nativeBinding = mapBinding(b->binding, QMetalShaderResourceBindingsData::COMPUTE, nativeResourceBindingMaps, BindingType::Buffer);
                if (nativeBinding >= 0)
                    bindingData.res[QMetalShaderResourceBindingsData::COMPUTE].buffers.append({ nativeBinding, mtlbuf, offset });
            }
        }
            break;
        default:
            Q_UNREACHABLE();
            break;
        }
    }

    for (int stage = 0; stage < SUPPORTED_STAGES; ++stage) {
        if (cbD->recordingPass != QMetalCommandBuffer::RenderPass && (stage == QMetalShaderResourceBindingsData::VERTEX || stage == QMetalShaderResourceBindingsData::FRAGMENT))
            continue;
        if (cbD->recordingPass != QMetalCommandBuffer::ComputePass && stage == QMetalShaderResourceBindingsData::COMPUTE)
            continue;

        // QRhiBatchedBindings works with the native bindings and expects
        // sorted input. The pre-sorted QRhiShaderResourceBinding list (based
        // on the QRhi (SPIR-V) binding) is not helpful in this regard, so we
        // have to sort here every time.

        std::sort(bindingData.res[stage].buffers.begin(), bindingData.res[stage].buffers.end(), [](const QMetalShaderResourceBindingsData::Stage::Buffer &a, const QMetalShaderResourceBindingsData::Stage::Buffer &b) {
            return a.nativeBinding < b.nativeBinding;
        });

        for (const QMetalShaderResourceBindingsData::Stage::Buffer &buf : std::as_const(bindingData.res[stage].buffers)) {
            bindingData.res[stage].bufferBatches.feed(buf.nativeBinding, buf.mtlbuf);
            bindingData.res[stage].bufferOffsetBatches.feed(buf.nativeBinding, buf.offset);
        }

        bindingData.res[stage].bufferBatches.finish();
        bindingData.res[stage].bufferOffsetBatches.finish();

        for (int i = 0, ie = bindingData.res[stage].bufferBatches.batches.count(); i != ie; ++i) {
            const auto &bufferBatch(bindingData.res[stage].bufferBatches.batches[i]);
            const auto &offsetBatch(bindingData.res[stage].bufferOffsetBatches.batches[i]);
            // skip setting Buffer binding if the current state is already correct
            if (cbD->d->currentShaderResourceBindingState.res[stage].bufferBatches.batches.count() > i
                    && cbD->d->currentShaderResourceBindingState.res[stage].bufferOffsetBatches.batches.count() > i
                    && bufferBatch == cbD->d->currentShaderResourceBindingState.res[stage].bufferBatches.batches[i]
                    && offsetBatch == cbD->d->currentShaderResourceBindingState.res[stage].bufferOffsetBatches.batches[i])
            {
                continue;
            }
            bindStageBuffers(cbD, stage, bufferBatch, offsetBatch);
        }

        if (offsetOnlyChange)
            continue;

        std::sort(bindingData.res[stage].textures.begin(), bindingData.res[stage].textures.end(), [](const QMetalShaderResourceBindingsData::Stage::Texture &a, const QMetalShaderResourceBindingsData::Stage::Texture &b) {
            return a.nativeBinding < b.nativeBinding;
        });

        std::sort(bindingData.res[stage].samplers.begin(), bindingData.res[stage].samplers.end(), [](const QMetalShaderResourceBindingsData::Stage::Sampler &a, const QMetalShaderResourceBindingsData::Stage::Sampler &b) {
            return a.nativeBinding < b.nativeBinding;
        });

        for (const QMetalShaderResourceBindingsData::Stage::Texture &t : std::as_const(bindingData.res[stage].textures))
            bindingData.res[stage].textureBatches.feed(t.nativeBinding, t.mtltex);

        for (const QMetalShaderResourceBindingsData::Stage::Sampler &s : std::as_const(bindingData.res[stage].samplers))
            bindingData.res[stage].samplerBatches.feed(s.nativeBinding, s.mtlsampler);

        bindingData.res[stage].textureBatches.finish();
        bindingData.res[stage].samplerBatches.finish();

        for (int i = 0, ie = bindingData.res[stage].textureBatches.batches.count(); i != ie; ++i) {
            const auto &batch(bindingData.res[stage].textureBatches.batches[i]);
            // skip setting Texture binding if the current state is already correct
            if (cbD->d->currentShaderResourceBindingState.res[stage].textureBatches.batches.count() > i
                    && batch == cbD->d->currentShaderResourceBindingState.res[stage].textureBatches.batches[i])
            {
                continue;
            }
            bindStageTextures(cbD, stage, batch);
        }

        for (int i = 0, ie = bindingData.res[stage].samplerBatches.batches.count(); i != ie; ++i) {
            const auto &batch(bindingData.res[stage].samplerBatches.batches[i]);
            // skip setting Sampler State if the current state is already correct
            if (cbD->d->currentShaderResourceBindingState.res[stage].samplerBatches.batches.count() > i
                && batch == cbD->d->currentShaderResourceBindingState.res[stage].samplerBatches.batches[i])
            {
                continue;
            }
            bindStageSamplers(cbD, stage, batch);
        }
    }

    cbD->d->currentShaderResourceBindingState = bindingData;
}

void QMetalGraphicsPipeline::makeActiveForCurrentRenderPassEncoder(QMetalCommandBuffer *cbD)
{
    [cbD->d->currentRenderPassEncoder setRenderPipelineState: d->ps];

    if (cbD->d->currentDepthStencilState != d->ds) {
        [cbD->d->currentRenderPassEncoder setDepthStencilState: d->ds];
        cbD->d->currentDepthStencilState = d->ds;
    }

    if (cbD->currentCullMode == -1 || d->cullMode != uint(cbD->currentCullMode)) {
        [cbD->d->currentRenderPassEncoder setCullMode: d->cullMode];
        cbD->currentCullMode = int(d->cullMode);
    }
    if (cbD->currentTriangleFillMode == -1 || d->triangleFillMode != uint(cbD->currentTriangleFillMode)) {
        [cbD->d->currentRenderPassEncoder setTriangleFillMode: d->triangleFillMode];
        cbD->currentTriangleFillMode = int(d->triangleFillMode);
    }
    if (cbD->currentFrontFaceWinding == -1 || d->winding != uint(cbD->currentFrontFaceWinding)) {
        [cbD->d->currentRenderPassEncoder setFrontFacingWinding: d->winding];
        cbD->currentFrontFaceWinding = int(d->winding);
    }
    if (!qFuzzyCompare(d->depthBias, cbD->currentDepthBiasValues.first)
            || !qFuzzyCompare(d->slopeScaledDepthBias, cbD->currentDepthBiasValues.second))
    {
        [cbD->d->currentRenderPassEncoder setDepthBias: d->depthBias
                                                        slopeScale: d->slopeScaledDepthBias
                                                        clamp: 0.0f];
        cbD->currentDepthBiasValues = { d->depthBias, d->slopeScaledDepthBias };
    }
}

void QRhiMetal::setGraphicsPipeline(QRhiCommandBuffer *cb, QRhiGraphicsPipeline *ps)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);
    QMetalGraphicsPipeline *psD = QRHI_RES(QMetalGraphicsPipeline, ps);

    if (cbD->currentGraphicsPipeline == psD && cbD->currentPipelineGeneration == psD->generation)
        return;

    cbD->currentGraphicsPipeline = psD;
    cbD->currentComputePipeline = nullptr;
    cbD->currentPipelineGeneration = psD->generation;

    if (!psD->d->tess.enabled && !psD->d->tess.failed) {
        psD->makeActiveForCurrentRenderPassEncoder(cbD);
    } else {
        // mark work buffers that can now be safely reused as reusable
        for (QMetalBuffer *workBuf : psD->d->tess.deviceLocalWorkBuffers) {
            if (workBuf && workBuf->lastActiveFrameSlot == currentFrameSlot)
                workBuf->lastActiveFrameSlot = -1;
        }
        for (QMetalBuffer *workBuf : psD->d->tess.hostVisibleWorkBuffers) {
            if (workBuf && workBuf->lastActiveFrameSlot == currentFrameSlot)
                workBuf->lastActiveFrameSlot = -1;
        }
    }

    psD->lastActiveFrameSlot = currentFrameSlot;
}

void QRhiMetal::setShaderResources(QRhiCommandBuffer *cb, QRhiShaderResourceBindings *srb,
                                   int dynamicOffsetCount,
                                   const QRhiCommandBuffer::DynamicOffset *dynamicOffsets)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass != QMetalCommandBuffer::NoPass);
    QMetalGraphicsPipeline *gfxPsD = cbD->currentGraphicsPipeline;
    QMetalComputePipeline *compPsD = cbD->currentComputePipeline;

    if (!srb) {
        if (gfxPsD)
            srb = gfxPsD->m_shaderResourceBindings;
        else
            srb = compPsD->m_shaderResourceBindings;
    }

    QMetalShaderResourceBindings *srbD = QRHI_RES(QMetalShaderResourceBindings, srb);
    bool hasSlottedResourceInSrb = false;
    bool hasDynamicOffsetInSrb = false;
    bool resNeedsRebind = false;

    // do buffer writes, figure out if we need to rebind, and mark as in-use
    for (int i = 0, ie = srbD->sortedBindings.count(); i != ie; ++i) {
        const QRhiShaderResourceBinding::Data *b = srbD->sortedBindings.at(i).data();
        QMetalShaderResourceBindings::BoundResourceData &bd(srbD->boundResourceData[i]);
        switch (b->type) {
        case QRhiShaderResourceBinding::UniformBuffer:
        {
            QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, b->u.ubuf.buf);
            Q_ASSERT(bufD->m_usage.testFlag(QRhiBuffer::UniformBuffer));
            executeBufferHostWritesForCurrentFrame(bufD);
            if (bufD->d->slotted)
                hasSlottedResourceInSrb = true;
            if (b->u.ubuf.hasDynamicOffset)
                hasDynamicOffsetInSrb = true;
            if (bufD->generation != bd.ubuf.generation || bufD->m_id != bd.ubuf.id) {
                resNeedsRebind = true;
                bd.ubuf.id = bufD->m_id;
                bd.ubuf.generation = bufD->generation;
            }
            bufD->lastActiveFrameSlot = currentFrameSlot;
        }
            break;
        case QRhiShaderResourceBinding::SampledTexture:
        case QRhiShaderResourceBinding::Texture:
        case QRhiShaderResourceBinding::Sampler:
        {
            const QRhiShaderResourceBinding::Data::TextureAndOrSamplerData *data = &b->u.stex;
            if (bd.stex.count != data->count) {
                bd.stex.count = data->count;
                resNeedsRebind = true;
            }
            for (int elem = 0; elem < data->count; ++elem) {
                QMetalTexture *texD = QRHI_RES(QMetalTexture, data->texSamplers[elem].tex);
                QMetalSampler *samplerD = QRHI_RES(QMetalSampler, data->texSamplers[elem].sampler);
                Q_ASSERT(texD || samplerD);
                const quint64 texId = texD ? texD->m_id : 0;
                const uint texGen = texD ? texD->generation : 0;
                const quint64 samplerId = samplerD ? samplerD->m_id : 0;
                const uint samplerGen = samplerD ? samplerD->generation : 0;
                if (texGen != bd.stex.d[elem].texGeneration
                        || texId != bd.stex.d[elem].texId
                        || samplerGen != bd.stex.d[elem].samplerGeneration
                        || samplerId != bd.stex.d[elem].samplerId)
                {
                    resNeedsRebind = true;
                    bd.stex.d[elem].texId = texId;
                    bd.stex.d[elem].texGeneration = texGen;
                    bd.stex.d[elem].samplerId = samplerId;
                    bd.stex.d[elem].samplerGeneration = samplerGen;
                }
                if (texD)
                    texD->lastActiveFrameSlot = currentFrameSlot;
                if (samplerD)
                    samplerD->lastActiveFrameSlot = currentFrameSlot;
            }
        }
            break;
        case QRhiShaderResourceBinding::ImageLoad:
        case QRhiShaderResourceBinding::ImageStore:
        case QRhiShaderResourceBinding::ImageLoadStore:
        {
            QMetalTexture *texD = QRHI_RES(QMetalTexture, b->u.simage.tex);
            if (texD->generation != bd.simage.generation || texD->m_id != bd.simage.id) {
                resNeedsRebind = true;
                bd.simage.id = texD->m_id;
                bd.simage.generation = texD->generation;
            }
            texD->lastActiveFrameSlot = currentFrameSlot;
        }
            break;
        case QRhiShaderResourceBinding::BufferLoad:
        case QRhiShaderResourceBinding::BufferStore:
        case QRhiShaderResourceBinding::BufferLoadStore:
        {
            QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, b->u.sbuf.buf);
            Q_ASSERT(bufD->m_usage.testFlag(QRhiBuffer::StorageBuffer));
            executeBufferHostWritesForCurrentFrame(bufD);
            if (bufD->generation != bd.sbuf.generation || bufD->m_id != bd.sbuf.id) {
                resNeedsRebind = true;
                bd.sbuf.id = bufD->m_id;
                bd.sbuf.generation = bufD->generation;
            }
            bufD->lastActiveFrameSlot = currentFrameSlot;
        }
            break;
        default:
            Q_UNREACHABLE();
            break;
        }
    }

    // make sure the resources for the correct slot get bound
    const int resSlot = hasSlottedResourceInSrb ? currentFrameSlot : 0;
    if (hasSlottedResourceInSrb && cbD->currentResSlot != resSlot)
        resNeedsRebind = true;

    const bool srbChanged = gfxPsD ? (cbD->currentGraphicsSrb != srbD) : (cbD->currentComputeSrb != srbD);
    const bool srbRebuilt = cbD->currentSrbGeneration != srbD->generation;

    // dynamic uniform buffer offsets always trigger a rebind
    if (hasDynamicOffsetInSrb || resNeedsRebind || srbChanged || srbRebuilt) {
        const QShader::NativeResourceBindingMap *resBindMaps[SUPPORTED_STAGES] = { nullptr, nullptr, nullptr };
        if (gfxPsD) {
            cbD->currentGraphicsSrb = srbD;
            cbD->currentComputeSrb = nullptr;
            resBindMaps[0] = &gfxPsD->d->vs.nativeResourceBindingMap;
            resBindMaps[1] = &gfxPsD->d->fs.nativeResourceBindingMap;
        } else {
            cbD->currentGraphicsSrb = nullptr;
            cbD->currentComputeSrb = srbD;
            resBindMaps[2] = &compPsD->d->cs.nativeResourceBindingMap;
        }
        cbD->currentSrbGeneration = srbD->generation;
        cbD->currentResSlot = resSlot;

        const bool offsetOnlyChange = hasDynamicOffsetInSrb && !resNeedsRebind && !srbChanged && !srbRebuilt;
        enqueueShaderResourceBindings(srbD, cbD, dynamicOffsetCount, dynamicOffsets, offsetOnlyChange, resBindMaps);
    }
}

void QRhiMetal::setVertexInput(QRhiCommandBuffer *cb,
                               int startBinding, int bindingCount, const QRhiCommandBuffer::VertexInput *bindings,
                               QRhiBuffer *indexBuf, quint32 indexOffset, QRhiCommandBuffer::IndexFormat indexFormat)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);

    QRhiBatchedBindings<id<MTLBuffer> > buffers;
    QRhiBatchedBindings<NSUInteger> offsets;
    for (int i = 0; i < bindingCount; ++i) {
        QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, bindings[i].first);
        executeBufferHostWritesForCurrentFrame(bufD);
        bufD->lastActiveFrameSlot = currentFrameSlot;
        id<MTLBuffer> mtlbuf = bufD->d->buf[bufD->d->slotted ? currentFrameSlot : 0];
        buffers.feed(startBinding + i, mtlbuf);
        offsets.feed(startBinding + i, bindings[i].second);
    }
    buffers.finish();
    offsets.finish();

    // same binding space for vertex and constant buffers - work it around
    QMetalShaderResourceBindings *srbD = cbD->currentGraphicsSrb;
    // There's nothing guaranteeing setShaderResources() was called before
    // setVertexInput()... but whatever srb will get bound will have to be
    // layout-compatible anyways so maxBinding is the same.
    if (!srbD)
        srbD = QRHI_RES(QMetalShaderResourceBindings, cbD->currentGraphicsPipeline->shaderResourceBindings());
    const int firstVertexBinding = srbD->maxBinding + 1;

    if (firstVertexBinding != cbD->d->currentFirstVertexBinding
            || buffers != cbD->d->currentVertexInputsBuffers
            || offsets != cbD->d->currentVertexInputOffsets)
    {
        cbD->d->currentFirstVertexBinding = firstVertexBinding;
        cbD->d->currentVertexInputsBuffers = buffers;
        cbD->d->currentVertexInputOffsets = offsets;

        for (int i = 0, ie = buffers.batches.count(); i != ie; ++i) {
            const auto &bufferBatch(buffers.batches[i]);
            const auto &offsetBatch(offsets.batches[i]);
            [cbD->d->currentRenderPassEncoder setVertexBuffers:
                bufferBatch.resources.constData()
              offsets: offsetBatch.resources.constData()
              withRange: NSMakeRange(uint(firstVertexBinding) + bufferBatch.startBinding, NSUInteger(bufferBatch.resources.count()))];
        }
    }

    if (indexBuf) {
        QMetalBuffer *ibufD = QRHI_RES(QMetalBuffer, indexBuf);
        executeBufferHostWritesForCurrentFrame(ibufD);
        ibufD->lastActiveFrameSlot = currentFrameSlot;
        cbD->currentIndexBuffer = ibufD;
        cbD->currentIndexOffset = indexOffset;
        cbD->currentIndexFormat = indexFormat;
    } else {
        cbD->currentIndexBuffer = nullptr;
    }
}

void QRhiMetal::setViewport(QRhiCommandBuffer *cb, const QRhiViewport &viewport)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);
    const QSize outputSize = cbD->currentTarget->pixelSize();

    // x,y is top-left in MTLViewportRect but bottom-left in QRhiViewport
    float x, y, w, h;
    if (!qrhi_toTopLeftRenderTargetRect<UnBounded>(outputSize, viewport.viewport(), &x, &y, &w, &h))
        return;

    MTLViewport vp;
    vp.originX = double(x);
    vp.originY = double(y);
    vp.width = double(w);
    vp.height = double(h);
    vp.znear = double(viewport.minDepth());
    vp.zfar = double(viewport.maxDepth());

    [cbD->d->currentRenderPassEncoder setViewport: vp];

    if (cbD->currentGraphicsPipeline
        && !cbD->currentGraphicsPipeline->m_flags.testFlag(QRhiGraphicsPipeline::UsesScissor)) {
        MTLScissorRect s;
        qrhi_toTopLeftRenderTargetRect<Bounded>(outputSize, viewport.viewport(), &x, &y, &w, &h);
        s.x = NSUInteger(x);
        s.y = NSUInteger(y);
        s.width = NSUInteger(w);
        s.height = NSUInteger(h);
        [cbD->d->currentRenderPassEncoder setScissorRect: s];
    }
}

void QRhiMetal::setScissor(QRhiCommandBuffer *cb, const QRhiScissor &scissor)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);
    Q_ASSERT(cbD->currentGraphicsPipeline->m_flags.testFlag(QRhiGraphicsPipeline::UsesScissor));
    const QSize outputSize = cbD->currentTarget->pixelSize();

    // x,y is top-left in MTLScissorRect but bottom-left in QRhiScissor
    int x, y, w, h;
    if (!qrhi_toTopLeftRenderTargetRect<Bounded>(outputSize, scissor.scissor(), &x, &y, &w, &h))
        return;

    MTLScissorRect s;
    s.x = NSUInteger(x);
    s.y = NSUInteger(y);
    s.width = NSUInteger(w);
    s.height = NSUInteger(h);

    [cbD->d->currentRenderPassEncoder setScissorRect: s];
}

void QRhiMetal::setBlendConstants(QRhiCommandBuffer *cb, const QColor &c)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);

    [cbD->d->currentRenderPassEncoder setBlendColorRed: float(c.redF())
      green: float(c.greenF()) blue: float(c.blueF()) alpha: float(c.alphaF())];
}

void QRhiMetal::setStencilRef(QRhiCommandBuffer *cb, quint32 refValue)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);

    [cbD->d->currentRenderPassEncoder setStencilReferenceValue: refValue];
}

static id<MTLComputeCommandEncoder> tessellationComputeEncoder(QMetalCommandBuffer *cbD)
{
    if (cbD->d->currentRenderPassEncoder) {
        [cbD->d->currentRenderPassEncoder endEncoding];
        cbD->d->currentRenderPassEncoder = nil;
    }

    if (!cbD->d->tessellationComputeEncoder)
        cbD->d->tessellationComputeEncoder = [cbD->d->cb computeCommandEncoder];

    return cbD->d->tessellationComputeEncoder;
}

static void endTessellationComputeEncoding(QMetalCommandBuffer *cbD)
{
    if (cbD->d->tessellationComputeEncoder) {
        [cbD->d->tessellationComputeEncoder endEncoding];
        cbD->d->tessellationComputeEncoder = nil;
    }

    cbD->d->currentRenderPassEncoder = [cbD->d->cb renderCommandEncoderWithDescriptor: cbD->d->currentPassRpDesc];
    cbD->resetPerPassCachedState();
}

void QRhiMetal::tessellatedDraw(const TessDrawArgs &args)
{
    QMetalCommandBuffer *cbD = args.cbD;
    QMetalGraphicsPipeline *graphicsPipeline = cbD->currentGraphicsPipeline;
    if (graphicsPipeline->d->tess.failed)
        return;

    const bool indexed = args.type != TessDrawArgs::NonIndexed;
    const quint32 instanceCount = indexed ? args.drawIndexed.instanceCount : args.draw.instanceCount;
    const quint32 vertexOrIndexCount = indexed ? args.drawIndexed.indexCount : args.draw.vertexCount;

    QMetalGraphicsPipelineData::Tessellation &tess(graphicsPipeline->d->tess);
    const quint32 patchCount = tess.patchCountForDrawCall(vertexOrIndexCount, instanceCount);
    QMetalBuffer *vertOutBuf = nullptr;
    QMetalBuffer *tescOutBuf = nullptr;
    QMetalBuffer *tescPatchOutBuf = nullptr;
    QMetalBuffer *tescFactorBuf = nullptr;
    QMetalBuffer *tescParamsBuf = nullptr;
    id<MTLComputeCommandEncoder> vertTescComputeEncoder = tessellationComputeEncoder(cbD);

    // Step 1: vertex shader (as compute)
    {
        id<MTLComputeCommandEncoder> computeEncoder = vertTescComputeEncoder;
        QShader::Variant shaderVariant = QShader::NonIndexedVertexAsComputeShader;
        if (args.type == TessDrawArgs::U16Indexed)
            shaderVariant = QShader::UInt16IndexedVertexAsComputeShader;
        else if (args.type == TessDrawArgs::U32Indexed)
            shaderVariant = QShader::UInt32IndexedVertexAsComputeShader;
        const int varIndex = QMetalGraphicsPipelineData::Tessellation::vsCompVariantToIndex(shaderVariant);
        id<MTLComputePipelineState> computePipelineState = tess.vsCompPipeline(this, shaderVariant);
        [computeEncoder setComputePipelineState: computePipelineState];

        // Make uniform buffers, textures, and samplers (meant for the
        // vertex stage from the client's point of view) visible in the
        // compute shaders (both vertex and tess.control).
        cbD->d->currentComputePassEncoder = computeEncoder;
        rebindShaderResources(cbD, QMetalShaderResourceBindingsData::VERTEX, QMetalShaderResourceBindingsData::COMPUTE);
        cbD->d->currentComputePassEncoder = nil;

        const QMap<int, int> &ebb(tess.compVs[varIndex].nativeShaderInfo.extraBufferBindings);
        const int outputBufferBinding = ebb.value(QShaderPrivate::MslTessVertTescOutputBufferBinding, -1);
        const int indexBufferBinding = ebb.value(QShaderPrivate::MslTessVertIndicesBufferBinding, -1);

        if (outputBufferBinding >= 0) {
            const quint32 workBufSize = tess.vsCompOutputBufferSize(vertexOrIndexCount, instanceCount);
            vertOutBuf = tess.acquireWorkBuffer(this, workBufSize);
            if (!vertOutBuf)
                return;
            [computeEncoder setBuffer: vertOutBuf->d->buf[0] offset: 0 atIndex: outputBufferBinding];
        }

        if (indexBufferBinding >= 0)
            [computeEncoder setBuffer: (id<MTLBuffer>) args.drawIndexed.indexBuffer offset: 0 atIndex: indexBufferBinding];

        for (int i = 0, ie = cbD->d->currentVertexInputsBuffers.batches.count(); i != ie; ++i) {
            const auto &bufferBatch(cbD->d->currentVertexInputsBuffers.batches[i]);
            const auto &offsetBatch(cbD->d->currentVertexInputOffsets.batches[i]);
            [computeEncoder setBuffers: bufferBatch.resources.constData()
              offsets: offsetBatch.resources.constData()
              withRange: NSMakeRange(uint(cbD->d->currentFirstVertexBinding) + bufferBatch.startBinding, NSUInteger(bufferBatch.resources.count()))];
        }

        if (indexed) {
            [computeEncoder setStageInRegion: MTLRegionMake2D(args.drawIndexed.vertexOffset, args.drawIndexed.firstInstance,
                                                              args.drawIndexed.indexCount, args.drawIndexed.instanceCount)];
        } else {
            [computeEncoder setStageInRegion: MTLRegionMake2D(args.draw.firstVertex, args.draw.firstInstance,
                                                              args.draw.vertexCount, args.draw.instanceCount)];
        }

        [computeEncoder dispatchThreads: MTLSizeMake(vertexOrIndexCount, instanceCount, 1)
          threadsPerThreadgroup: MTLSizeMake(computePipelineState.threadExecutionWidth, 1, 1)];
    }

    // Step 2: tessellation control shader (as compute)
    {
        id<MTLComputeCommandEncoder> computeEncoder = vertTescComputeEncoder;
        id<MTLComputePipelineState> computePipelineState = tess.tescCompPipeline(this);
        [computeEncoder setComputePipelineState: computePipelineState];

        // Shader resources are set already in step 1. (because srb stage
        // flags for tesc and tese visibility are treated as if they were
        // specified as vertex visibility -> QMSRBD::VERTEX includes those too)

        const QMap<int, int> &ebb(tess.compTesc.nativeShaderInfo.extraBufferBindings);
        const int outputBufferBinding = ebb.value(QShaderPrivate::MslTessVertTescOutputBufferBinding, -1);
        const int patchOutputBufferBinding = ebb.value(QShaderPrivate::MslTessTescPatchOutputBufferBinding, -1);
        const int tessFactorBufferBinding = ebb.value(QShaderPrivate::MslTessTescTessLevelBufferBinding, -1);
        const int paramsBufferBinding = ebb.value(QShaderPrivate::MslTessTescParamsBufferBinding, -1);
        const int inputBufferBinding = ebb.value(QShaderPrivate::MslTessTescInputBufferBinding, -1);

        if (outputBufferBinding >= 0) {
            const quint32 workBufSize = tess.tescCompOutputBufferSize(patchCount);
            tescOutBuf = tess.acquireWorkBuffer(this, workBufSize);
            if (!tescOutBuf)
                return;
            [computeEncoder setBuffer: tescOutBuf->d->buf[0] offset: 0 atIndex: outputBufferBinding];
        }

        if (patchOutputBufferBinding >= 0) {
            const quint32 workBufSize = tess.tescCompPatchOutputBufferSize(patchCount);
            tescPatchOutBuf = tess.acquireWorkBuffer(this, workBufSize);
            if (!tescPatchOutBuf)
                return;
            [computeEncoder setBuffer: tescPatchOutBuf->d->buf[0] offset: 0 atIndex: patchOutputBufferBinding];
        }

        if (tessFactorBufferBinding >= 0) {
            tescFactorBuf = tess.acquireWorkBuffer(this, patchCount * sizeof(MTLQuadTessellationFactorsHalf));
            [computeEncoder setBuffer: tescFactorBuf->d->buf[0] offset: 0 atIndex: tessFactorBufferBinding];
        }

        if (paramsBufferBinding >= 0) {
            struct {
                quint32 inControlPointCount;
                quint32 patchCount;
            } params;
            tescParamsBuf = tess.acquireWorkBuffer(this, sizeof(params), QMetalGraphicsPipelineData::Tessellation::WorkBufType::HostVisible);
            if (!tescParamsBuf)
                return;
            params.inControlPointCount = tess.inControlPointCount;
            params.patchCount = patchCount;
            id<MTLBuffer> paramsBuf = tescParamsBuf->d->buf[0];
            char *p = reinterpret_cast<char *>([paramsBuf contents]);
            memcpy(p, &params, sizeof(params));
            [computeEncoder setBuffer: paramsBuf offset: 0 atIndex: paramsBufferBinding];
        }

        if (vertOutBuf && inputBufferBinding >= 0)
            [computeEncoder setBuffer: vertOutBuf->d->buf[0] offset: 0 atIndex: inputBufferBinding];

        int sgSize = int(computePipelineState.threadExecutionWidth);
        int wgSize = std::lcm(tess.outControlPointCount, sgSize);
        while (wgSize > caps.maxThreadGroupSize) {
            sgSize /= 2;
            wgSize = std::lcm(tess.outControlPointCount, sgSize);
        }
        [computeEncoder dispatchThreads: MTLSizeMake(patchCount * tess.outControlPointCount, 1, 1)
          threadsPerThreadgroup: MTLSizeMake(wgSize, 1, 1)];
    }

    // Much of the state in the QMetalCommandBuffer is going to be reset
    // when we get a new render encoder. Save what we need. (cheaper than
    // starting to walk over the srb again)
    const QMetalShaderResourceBindingsData resourceBindings = cbD->d->currentShaderResourceBindingState;

    endTessellationComputeEncoding(cbD);

    // Step 3: tessellation evaluation (as vertex) + fragment shader
    {
        // No need to call tess.teseFragRenderPipeline because it was done
        // once and we know the result is stored in the standard place
        // (graphicsPipeline->d->ps).

        graphicsPipeline->makeActiveForCurrentRenderPassEncoder(cbD);
        id<MTLRenderCommandEncoder> renderEncoder = cbD->d->currentRenderPassEncoder;

        rebindShaderResources(cbD, QMetalShaderResourceBindingsData::VERTEX, QMetalShaderResourceBindingsData::VERTEX, &resourceBindings);
        rebindShaderResources(cbD, QMetalShaderResourceBindingsData::FRAGMENT, QMetalShaderResourceBindingsData::FRAGMENT, &resourceBindings);

        const QMap<int, int> &ebb(tess.compTesc.nativeShaderInfo.extraBufferBindings);
        const int outputBufferBinding = ebb.value(QShaderPrivate::MslTessVertTescOutputBufferBinding, -1);
        const int patchOutputBufferBinding = ebb.value(QShaderPrivate::MslTessTescPatchOutputBufferBinding, -1);
        const int tessFactorBufferBinding = ebb.value(QShaderPrivate::MslTessTescTessLevelBufferBinding, -1);

        if (outputBufferBinding >= 0 && tescOutBuf)
            [renderEncoder setVertexBuffer: tescOutBuf->d->buf[0] offset: 0 atIndex: outputBufferBinding];

        if (patchOutputBufferBinding >= 0 && tescPatchOutBuf)
            [renderEncoder setVertexBuffer: tescPatchOutBuf->d->buf[0] offset: 0 atIndex: patchOutputBufferBinding];

        if (tessFactorBufferBinding >= 0 && tescFactorBuf) {
            [renderEncoder setTessellationFactorBuffer: tescFactorBuf->d->buf[0] offset: 0 instanceStride: 0];
            [renderEncoder setVertexBuffer: tescFactorBuf->d->buf[0] offset: 0 atIndex: tessFactorBufferBinding];
        }

        [cbD->d->currentRenderPassEncoder drawPatches: tess.outControlPointCount
                                                       patchStart: 0
                                                       patchCount: patchCount
                                                       patchIndexBuffer: nil
                                                       patchIndexBufferOffset: 0
                                                       instanceCount: 1
                                                       baseInstance: 0];
    }
}

void QRhiMetal::draw(QRhiCommandBuffer *cb, quint32 vertexCount,
                     quint32 instanceCount, quint32 firstVertex, quint32 firstInstance)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);

    if (cbD->currentGraphicsPipeline->d->tess.enabled) {
        TessDrawArgs a;
        a.cbD = cbD;
        a.type = TessDrawArgs::NonIndexed;
        a.draw.vertexCount = vertexCount;
        a.draw.instanceCount = instanceCount;
        a.draw.firstVertex = firstVertex;
        a.draw.firstInstance = firstInstance;
        tessellatedDraw(a);
        return;
    }

    if (caps.baseVertexAndInstance) {
        [cbD->d->currentRenderPassEncoder drawPrimitives: cbD->currentGraphicsPipeline->d->primitiveType
                                                          vertexStart: firstVertex vertexCount: vertexCount instanceCount: instanceCount baseInstance: firstInstance];
    } else {
        [cbD->d->currentRenderPassEncoder drawPrimitives: cbD->currentGraphicsPipeline->d->primitiveType
                                                          vertexStart: firstVertex vertexCount: vertexCount instanceCount: instanceCount];
    }
}

void QRhiMetal::drawIndexed(QRhiCommandBuffer *cb, quint32 indexCount,
                            quint32 instanceCount, quint32 firstIndex, qint32 vertexOffset, quint32 firstInstance)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);

    if (!cbD->currentIndexBuffer)
        return;

    const quint32 indexOffset = cbD->currentIndexOffset + firstIndex * (cbD->currentIndexFormat == QRhiCommandBuffer::IndexUInt16 ? 2 : 4);
    Q_ASSERT(indexOffset == aligned(indexOffset, 4u));

    QMetalBuffer *ibufD = cbD->currentIndexBuffer;
    id<MTLBuffer> mtlibuf = ibufD->d->buf[ibufD->d->slotted ? currentFrameSlot : 0];

    if (cbD->currentGraphicsPipeline->d->tess.enabled) {
        TessDrawArgs a;
        a.cbD = cbD;
        a.type = cbD->currentIndexFormat == QRhiCommandBuffer::IndexUInt16 ? TessDrawArgs::U16Indexed : TessDrawArgs::U32Indexed;
        a.drawIndexed.indexCount = indexCount;
        a.drawIndexed.instanceCount = instanceCount;
        a.drawIndexed.firstIndex = firstIndex;
        a.drawIndexed.vertexOffset = vertexOffset;
        a.drawIndexed.firstInstance = firstInstance;
        a.drawIndexed.indexBuffer = mtlibuf;
        tessellatedDraw(a);
        return;
    }

    if (caps.baseVertexAndInstance) {
        [cbD->d->currentRenderPassEncoder drawIndexedPrimitives: cbD->currentGraphicsPipeline->d->primitiveType
          indexCount: indexCount
          indexType: cbD->currentIndexFormat == QRhiCommandBuffer::IndexUInt16 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32
          indexBuffer: mtlibuf
          indexBufferOffset: indexOffset
          instanceCount: instanceCount
          baseVertex: vertexOffset
          baseInstance: firstInstance];
    } else {
        [cbD->d->currentRenderPassEncoder drawIndexedPrimitives: cbD->currentGraphicsPipeline->d->primitiveType
          indexCount: indexCount
          indexType: cbD->currentIndexFormat == QRhiCommandBuffer::IndexUInt16 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32
          indexBuffer: mtlibuf
          indexBufferOffset: indexOffset
          instanceCount: instanceCount];
    }
}

void QRhiMetal::debugMarkBegin(QRhiCommandBuffer *cb, const QByteArray &name)
{
    if (!debugMarkers)
        return;

    NSString *str = [NSString stringWithUTF8String: name.constData()];
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    if (cbD->recordingPass != QMetalCommandBuffer::NoPass)
        [cbD->d->currentRenderPassEncoder pushDebugGroup: str];
    else
        [cbD->d->cb pushDebugGroup: str];
}

void QRhiMetal::debugMarkEnd(QRhiCommandBuffer *cb)
{
    if (!debugMarkers)
        return;

    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    if (cbD->recordingPass != QMetalCommandBuffer::NoPass)
        [cbD->d->currentRenderPassEncoder popDebugGroup];
    else
        [cbD->d->cb popDebugGroup];
}

void QRhiMetal::debugMarkMsg(QRhiCommandBuffer *cb, const QByteArray &msg)
{
    if (!debugMarkers)
        return;

    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    if (cbD->recordingPass != QMetalCommandBuffer::NoPass)
        [cbD->d->currentRenderPassEncoder insertDebugSignpost: [NSString stringWithUTF8String: msg.constData()]];
}

const QRhiNativeHandles *QRhiMetal::nativeHandles(QRhiCommandBuffer *cb)
{
    return QRHI_RES(QMetalCommandBuffer, cb)->nativeHandles();
}

void QRhiMetal::beginExternal(QRhiCommandBuffer *cb)
{
    Q_UNUSED(cb);
}

void QRhiMetal::endExternal(QRhiCommandBuffer *cb)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    cbD->resetPerPassCachedState();
}

QRhi::FrameOpResult QRhiMetal::beginFrame(QRhiSwapChain *swapChain, QRhi::BeginFrameFlags flags)
{
    Q_UNUSED(flags);

    QMetalSwapChain *swapChainD = QRHI_RES(QMetalSwapChain, swapChain);

    // This is a bit messed up since for this swapchain we want to wait for the
    // commands+present to complete, while for others just for the commands
    // (for this same frame slot) but not sure how to do that in a sane way so
    // wait for full cb completion for now.
    for (QMetalSwapChain *sc : std::as_const(swapchains)) {
        dispatch_semaphore_t sem = sc->d->sem[swapChainD->currentFrameSlot];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        if (sc != swapChainD)
            dispatch_semaphore_signal(sem);
    }

    currentSwapChain = swapChainD;
    currentFrameSlot = swapChainD->currentFrameSlot;
    if (swapChainD->ds)
        swapChainD->ds->lastActiveFrameSlot = currentFrameSlot;

    [d->captureScope beginScope];

    // Do not let the command buffer mess with the refcount of objects. We do
    // have a proper render loop and will manage lifetimes similarly to other
    // backends (Vulkan).
    swapChainD->cbWrapper.d->cb = [d->cmdQueue commandBufferWithUnretainedReferences];

    QMetalRenderTargetData::ColorAtt colorAtt;
    if (swapChainD->samples > 1) {
        colorAtt.tex = swapChainD->d->msaaTex[currentFrameSlot];
        colorAtt.needsDrawableForResolveTex = true;
    } else {
        colorAtt.needsDrawableForTex = true;
    }

    swapChainD->rtWrapper.d->fb.colorAtt[0] = colorAtt;
    swapChainD->rtWrapper.d->fb.dsTex = swapChainD->ds ? swapChainD->ds->d->tex : nil;
    swapChainD->rtWrapper.d->fb.hasStencil = swapChainD->ds ? true : false;
    swapChainD->rtWrapper.d->fb.depthNeedsStore = false;

    executeDeferredReleases();
    swapChainD->cbWrapper.resetState();
    finishActiveReadbacks();

    return QRhi::FrameOpSuccess;
}

QRhi::FrameOpResult QRhiMetal::endFrame(QRhiSwapChain *swapChain, QRhi::EndFrameFlags flags)
{
    QMetalSwapChain *swapChainD = QRHI_RES(QMetalSwapChain, swapChain);
    Q_ASSERT(currentSwapChain == swapChainD);

    const bool needsPresent = !flags.testFlag(QRhi::SkipPresent);
    if (needsPresent) {
        // beginFrame-endFrame without a render pass inbetween means there is no
        // drawable, handle this gracefully because presentDrawable does not like
        // null arguments.
        if (id<CAMetalDrawable> drawable = swapChainD->d->curDrawable) {
            // QTBUG-103415: while the docs suggest the following two approaches are
            // equivalent, there is a difference in case a frame is recorded earlier than
            // (i.e. not in response to) the next CVDisplayLink callback. Therefore, stick
            // with presentDrawable, which gives results identical to OpenGL, and all other
            // platforms, i.e. throttles to vsync as expected, meaning constant 15-17 ms with
            // a 60 Hz screen, no jumps with smaller intervals, regardless of when the frame
            // is submitted by the app)
#if 1
            [swapChainD->cbWrapper.d->cb presentDrawable: drawable];
#else
            [swapChainD->cbWrapper.d->cb addScheduledHandler:^(id<MTLCommandBuffer>) {
                [drawable present];
            }];
#endif
        }
    }

    // Must not hold on to the drawable, regardless of needsPresent
    [swapChainD->d->curDrawable release];
    swapChainD->d->curDrawable = nil;

    __block int thisFrameSlot = currentFrameSlot;
    [swapChainD->cbWrapper.d->cb addCompletedHandler: ^(id<MTLCommandBuffer>) {
        dispatch_semaphore_signal(swapChainD->d->sem[thisFrameSlot]);
    }];

    [swapChainD->cbWrapper.d->cb commit];

    [d->captureScope endScope];

    if (needsPresent)
        swapChainD->currentFrameSlot = (swapChainD->currentFrameSlot + 1) % QMTL_FRAMES_IN_FLIGHT;

    swapChainD->frameCount += 1;
    currentSwapChain = nullptr;
    return QRhi::FrameOpSuccess;
}

QRhi::FrameOpResult QRhiMetal::beginOffscreenFrame(QRhiCommandBuffer **cb, QRhi::BeginFrameFlags flags)
{
    Q_UNUSED(flags);

    currentFrameSlot = (currentFrameSlot + 1) % QMTL_FRAMES_IN_FLIGHT;
    if (swapchains.count() > 1) {
        for (QMetalSwapChain *sc : std::as_const(swapchains)) {
            // wait+signal is the general pattern to ensure the commands for a
            // given frame slot have completed (if sem is 1, we go 0 then 1; if
            // sem is 0 we go -1, block, completion increments to 0, then us to 1)
            dispatch_semaphore_t sem = sc->d->sem[currentFrameSlot];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(sem);
        }
    }

    d->ofr.active = true;
    *cb = &d->ofr.cbWrapper;
    d->ofr.cbWrapper.d->cb = [d->cmdQueue commandBufferWithUnretainedReferences];

    executeDeferredReleases();
    d->ofr.cbWrapper.resetState();
    finishActiveReadbacks();

    return QRhi::FrameOpSuccess;
}

QRhi::FrameOpResult QRhiMetal::endOffscreenFrame(QRhi::EndFrameFlags flags)
{
    Q_UNUSED(flags);
    Q_ASSERT(d->ofr.active);
    d->ofr.active = false;

    [d->ofr.cbWrapper.d->cb commit];

    // offscreen frames wait for completion, unlike swapchain ones
    [d->ofr.cbWrapper.d->cb waitUntilCompleted];

    finishActiveReadbacks(true);

    return QRhi::FrameOpSuccess;
}

QRhi::FrameOpResult QRhiMetal::finish()
{
    id<MTLCommandBuffer> cb = nil;
    QMetalSwapChain *swapChainD = nullptr;
    if (inFrame) {
        if (d->ofr.active) {
            Q_ASSERT(!currentSwapChain);
            Q_ASSERT(d->ofr.cbWrapper.recordingPass == QMetalCommandBuffer::NoPass);
            cb = d->ofr.cbWrapper.d->cb;
        } else {
            Q_ASSERT(currentSwapChain);
            swapChainD = currentSwapChain;
            Q_ASSERT(swapChainD->cbWrapper.recordingPass == QMetalCommandBuffer::NoPass);
            cb = swapChainD->cbWrapper.d->cb;
        }
    }

    for (QMetalSwapChain *sc : std::as_const(swapchains)) {
        for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
            if (currentSwapChain && sc == currentSwapChain && i == currentFrameSlot) {
                // no wait as this is the thing we're going to be commit below and
                // beginFrame decremented sem already and going to be signaled by endFrame
                continue;
            }
            dispatch_semaphore_t sem = sc->d->sem[i];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(sem);
        }
    }

    if (cb) {
        [cb commit];
        [cb waitUntilCompleted];
    }

    if (inFrame) {
        if (d->ofr.active)
            d->ofr.cbWrapper.d->cb = [d->cmdQueue commandBufferWithUnretainedReferences];
        else
            swapChainD->cbWrapper.d->cb = [d->cmdQueue commandBufferWithUnretainedReferences];
    }

    executeDeferredReleases(true);

    finishActiveReadbacks(true);

    return QRhi::FrameOpSuccess;
}

MTLRenderPassDescriptor *QRhiMetalData::createDefaultRenderPass(bool hasDepthStencil,
                                                                const QColor &colorClearValue,
                                                                const QRhiDepthStencilClearValue &depthStencilClearValue,
                                                                int colorAttCount)
{
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLClearColor c = MTLClearColorMake(colorClearValue.redF(), colorClearValue.greenF(), colorClearValue.blueF(),
                                        colorClearValue.alphaF());

    for (uint i = 0; i < uint(colorAttCount); ++i) {
        rp.colorAttachments[i].loadAction = MTLLoadActionClear;
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        rp.colorAttachments[i].clearColor = c;
    }

    if (hasDepthStencil) {
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.storeAction = MTLStoreActionDontCare;
        rp.stencilAttachment.loadAction = MTLLoadActionClear;
        rp.stencilAttachment.storeAction = MTLStoreActionDontCare;
        rp.depthAttachment.clearDepth = double(depthStencilClearValue.depthClearValue());
        rp.stencilAttachment.clearStencil = depthStencilClearValue.stencilClearValue();
    }

    return rp;
}

qsizetype QRhiMetal::subresUploadByteSize(const QRhiTextureSubresourceUploadDescription &subresDesc) const
{
    qsizetype size = 0;
    const qsizetype imageSizeBytes = subresDesc.image().isNull() ?
                subresDesc.data().size() : subresDesc.image().sizeInBytes();
    if (imageSizeBytes > 0)
        size += aligned<qsizetype>(imageSizeBytes, QRhiMetalData::TEXBUF_ALIGN);
    return size;
}

void QRhiMetal::enqueueSubresUpload(QMetalTexture *texD, void *mp, void *blitEncPtr,
                                    int layer, int level, const QRhiTextureSubresourceUploadDescription &subresDesc,
                                    qsizetype *curOfs)
{
    const QPoint dp = subresDesc.destinationTopLeft();
    const QByteArray rawData = subresDesc.data();
    QImage img = subresDesc.image();
    const bool is3D = texD->m_flags.testFlag(QRhiTexture::ThreeDimensional);
    id<MTLBlitCommandEncoder> blitEnc = (id<MTLBlitCommandEncoder>) blitEncPtr;

    if (!img.isNull()) {
        const qsizetype fullImageSizeBytes = img.sizeInBytes();
        int w = img.width();
        int h = img.height();
        int bpl = img.bytesPerLine();
        int srcOffset = 0;

        if (!subresDesc.sourceSize().isEmpty() || !subresDesc.sourceTopLeft().isNull()) {
            const int sx = subresDesc.sourceTopLeft().x();
            const int sy = subresDesc.sourceTopLeft().y();
            if (!subresDesc.sourceSize().isEmpty()) {
                w = subresDesc.sourceSize().width();
                h = subresDesc.sourceSize().height();
            }
            if (img.depth() == 32) {
                memcpy(reinterpret_cast<char *>(mp) + *curOfs, img.constBits(), size_t(fullImageSizeBytes));
                srcOffset = sy * bpl + sx * 4;
                // bpl remains set to the original image's row stride
            } else {
                img = img.copy(sx, sy, w, h);
                bpl = img.bytesPerLine();
                Q_ASSERT(img.sizeInBytes() <= fullImageSizeBytes);
                memcpy(reinterpret_cast<char *>(mp) + *curOfs, img.constBits(), size_t(img.sizeInBytes()));
            }
        } else {
            memcpy(reinterpret_cast<char *>(mp) + *curOfs, img.constBits(), size_t(fullImageSizeBytes));
        }

        [blitEnc copyFromBuffer: texD->d->stagingBuf[currentFrameSlot]
                                 sourceOffset: NSUInteger(*curOfs + srcOffset)
                                 sourceBytesPerRow: NSUInteger(bpl)
                                 sourceBytesPerImage: 0
                                 sourceSize: MTLSizeMake(NSUInteger(w), NSUInteger(h), 1)
          toTexture: texD->d->tex
          destinationSlice: NSUInteger(is3D ? 0 : layer)
          destinationLevel: NSUInteger(level)
          destinationOrigin: MTLOriginMake(NSUInteger(dp.x()), NSUInteger(dp.y()), NSUInteger(is3D ? layer : 0))
          options: MTLBlitOptionNone];

        *curOfs += aligned<qsizetype>(fullImageSizeBytes, QRhiMetalData::TEXBUF_ALIGN);
    } else if (!rawData.isEmpty() && isCompressedFormat(texD->m_format)) {
        const QSize subresSize = q->sizeForMipLevel(level, texD->m_pixelSize);
        const int subresw = subresSize.width();
        const int subresh = subresSize.height();
        int w, h;
        if (subresDesc.sourceSize().isEmpty()) {
            w = subresw;
            h = subresh;
        } else {
            w = subresDesc.sourceSize().width();
            h = subresDesc.sourceSize().height();
        }

        quint32 bpl = 0;
        QSize blockDim;
        compressedFormatInfo(texD->m_format, QSize(w, h), &bpl, nullptr, &blockDim);

        const int dx = aligned(dp.x(), blockDim.width());
        const int dy = aligned(dp.y(), blockDim.height());
        if (dx + w != subresw)
            w = aligned(w, blockDim.width());
        if (dy + h != subresh)
            h = aligned(h, blockDim.height());

        memcpy(reinterpret_cast<char *>(mp) + *curOfs, rawData.constData(), size_t(rawData.size()));

        [blitEnc copyFromBuffer: texD->d->stagingBuf[currentFrameSlot]
                                 sourceOffset: NSUInteger(*curOfs)
                                 sourceBytesPerRow: bpl
                                 sourceBytesPerImage: 0
                                 sourceSize: MTLSizeMake(NSUInteger(w), NSUInteger(h), 1)
          toTexture: texD->d->tex
          destinationSlice: NSUInteger(is3D ? 0 : layer)
          destinationLevel: NSUInteger(level)
          destinationOrigin: MTLOriginMake(NSUInteger(dx), NSUInteger(dy), NSUInteger(is3D ? layer : 0))
          options: MTLBlitOptionNone];

        *curOfs += aligned<qsizetype>(rawData.size(), QRhiMetalData::TEXBUF_ALIGN);
    } else if (!rawData.isEmpty()) {
        const QSize subresSize = q->sizeForMipLevel(level, texD->m_pixelSize);
        const int subresw = subresSize.width();
        const int subresh = subresSize.height();
        int w, h;
        if (subresDesc.sourceSize().isEmpty()) {
            w = subresw;
            h = subresh;
        } else {
            w = subresDesc.sourceSize().width();
            h = subresDesc.sourceSize().height();
        }

        quint32 bpl = 0;
        if (subresDesc.dataStride())
            bpl = subresDesc.dataStride();
        else
            textureFormatInfo(texD->m_format, QSize(w, h), &bpl, nullptr, nullptr);

        memcpy(reinterpret_cast<char *>(mp) + *curOfs, rawData.constData(), size_t(rawData.size()));

        [blitEnc copyFromBuffer: texD->d->stagingBuf[currentFrameSlot]
                                 sourceOffset: NSUInteger(*curOfs)
                                 sourceBytesPerRow: bpl
                                 sourceBytesPerImage: 0
                                 sourceSize: MTLSizeMake(NSUInteger(w), NSUInteger(h), 1)
          toTexture: texD->d->tex
          destinationSlice: NSUInteger(is3D ? 0 : layer)
          destinationLevel: NSUInteger(level)
          destinationOrigin: MTLOriginMake(NSUInteger(dp.x()), NSUInteger(dp.y()), NSUInteger(is3D ? layer : 0))
          options: MTLBlitOptionNone];

        *curOfs += aligned<qsizetype>(rawData.size(), QRhiMetalData::TEXBUF_ALIGN);
    } else {
        qWarning("Invalid texture upload for %p layer=%d mip=%d", texD, layer, level);
    }
}

void QRhiMetal::enqueueResourceUpdates(QRhiCommandBuffer *cb, QRhiResourceUpdateBatch *resourceUpdates)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    QRhiResourceUpdateBatchPrivate *ud = QRhiResourceUpdateBatchPrivate::get(resourceUpdates);

    for (int opIdx = 0; opIdx < ud->activeBufferOpCount; ++opIdx) {
        const QRhiResourceUpdateBatchPrivate::BufferOp &u(ud->bufferOps[opIdx]);
        if (u.type == QRhiResourceUpdateBatchPrivate::BufferOp::DynamicUpdate) {
            QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, u.buf);
            Q_ASSERT(bufD->m_type == QRhiBuffer::Dynamic);
            for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
                if (u.offset == 0 && u.data.size() == bufD->m_size)
                    bufD->d->pendingUpdates[i].clear();
                bufD->d->pendingUpdates[i].append({ u.offset, u.data });
            }
        } else if (u.type == QRhiResourceUpdateBatchPrivate::BufferOp::StaticUpload) {
            // Due to the Metal API the handling of static and dynamic buffers is
            // basically the same. So go through the same pendingUpdates machinery.
            QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, u.buf);
            Q_ASSERT(bufD->m_type != QRhiBuffer::Dynamic);
            Q_ASSERT(u.offset + u.data.size() <= bufD->m_size);
            for (int i = 0, ie = bufD->d->slotted ? QMTL_FRAMES_IN_FLIGHT : 1; i != ie; ++i)
                bufD->d->pendingUpdates[i].append({ u.offset, u.data });
        } else if (u.type == QRhiResourceUpdateBatchPrivate::BufferOp::Read) {
            QMetalBuffer *bufD = QRHI_RES(QMetalBuffer, u.buf);
            executeBufferHostWritesForCurrentFrame(bufD);
            const int idx = bufD->d->slotted ? currentFrameSlot : 0;
            if (bufD->m_type == QRhiBuffer::Dynamic) {
                char *p = reinterpret_cast<char *>([bufD->d->buf[idx] contents]);
                if (p) {
                    u.result->data.resize(u.readSize);
                    memcpy(u.result->data.data(), p + u.offset, size_t(u.readSize));
                }
                if (u.result->completed)
                    u.result->completed();
            } else {
                QRhiMetalData::BufferReadback readback;
                readback.activeFrameSlot = idx;
                readback.buf = bufD->d->buf[idx];
                readback.offset = u.offset;
                readback.readSize = u.readSize;
                readback.result = u.result;
                d->activeBufferReadbacks.append(readback);
            }
        }
    }

    id<MTLBlitCommandEncoder> blitEnc = nil;
    auto ensureBlit = [&blitEnc, cbD, this] {
        if (!blitEnc) {
            blitEnc = [cbD->d->cb blitCommandEncoder];
            if (debugMarkers)
                [blitEnc pushDebugGroup: @"Texture upload/copy"];
        }
    };

    for (int opIdx = 0; opIdx < ud->activeTextureOpCount; ++opIdx) {
        const QRhiResourceUpdateBatchPrivate::TextureOp &u(ud->textureOps[opIdx]);
        if (u.type == QRhiResourceUpdateBatchPrivate::TextureOp::Upload) {
            QMetalTexture *utexD = QRHI_RES(QMetalTexture, u.dst);
            qsizetype stagingSize = 0;
            for (int layer = 0, maxLayer = u.subresDesc.count(); layer < maxLayer; ++layer) {
                for (int level = 0; level < QRhi::MAX_MIP_LEVELS; ++level) {
                    for (const QRhiTextureSubresourceUploadDescription &subresDesc : std::as_const(u.subresDesc[layer][level]))
                        stagingSize += subresUploadByteSize(subresDesc);
                }
            }

            ensureBlit();
            Q_ASSERT(!utexD->d->stagingBuf[currentFrameSlot]);
            utexD->d->stagingBuf[currentFrameSlot] = [d->dev newBufferWithLength: NSUInteger(stagingSize)
                        options: MTLResourceStorageModeShared];

            void *mp = [utexD->d->stagingBuf[currentFrameSlot] contents];
            qsizetype curOfs = 0;
            for (int layer = 0, maxLayer = u.subresDesc.count(); layer < maxLayer; ++layer) {
                for (int level = 0; level < QRhi::MAX_MIP_LEVELS; ++level) {
                    for (const QRhiTextureSubresourceUploadDescription &subresDesc : std::as_const(u.subresDesc[layer][level]))
                        enqueueSubresUpload(utexD, mp, blitEnc, layer, level, subresDesc, &curOfs);
                }
            }

            utexD->lastActiveFrameSlot = currentFrameSlot;

            QRhiMetalData::DeferredReleaseEntry e;
            e.type = QRhiMetalData::DeferredReleaseEntry::StagingBuffer;
            e.lastActiveFrameSlot = currentFrameSlot;
            e.stagingBuffer.buffer = utexD->d->stagingBuf[currentFrameSlot];
            utexD->d->stagingBuf[currentFrameSlot] = nil;
            d->releaseQueue.append(e);
        } else if (u.type == QRhiResourceUpdateBatchPrivate::TextureOp::Copy) {
            Q_ASSERT(u.src && u.dst);
            QMetalTexture *srcD = QRHI_RES(QMetalTexture, u.src);
            QMetalTexture *dstD = QRHI_RES(QMetalTexture, u.dst);
            const bool srcIs3D = srcD->m_flags.testFlag(QRhiTexture::ThreeDimensional);
            const bool dstIs3D = dstD->m_flags.testFlag(QRhiTexture::ThreeDimensional);
            const QPoint dp = u.desc.destinationTopLeft();
            const QSize mipSize = q->sizeForMipLevel(u.desc.sourceLevel(), srcD->m_pixelSize);
            const QSize copySize = u.desc.pixelSize().isEmpty() ? mipSize : u.desc.pixelSize();
            const QPoint sp = u.desc.sourceTopLeft();

            ensureBlit();
            [blitEnc copyFromTexture: srcD->d->tex
                                      sourceSlice: NSUInteger(srcIs3D ? 0 : u.desc.sourceLayer())
                                      sourceLevel: NSUInteger(u.desc.sourceLevel())
                                      sourceOrigin: MTLOriginMake(NSUInteger(sp.x()), NSUInteger(sp.y()), NSUInteger(srcIs3D ? u.desc.sourceLayer() : 0))
                                      sourceSize: MTLSizeMake(NSUInteger(copySize.width()), NSUInteger(copySize.height()), 1)
                                      toTexture: dstD->d->tex
                                      destinationSlice: NSUInteger(dstIs3D ? 0 : u.desc.destinationLayer())
                                      destinationLevel: NSUInteger(u.desc.destinationLevel())
                                      destinationOrigin: MTLOriginMake(NSUInteger(dp.x()), NSUInteger(dp.y()), NSUInteger(dstIs3D ? u.desc.destinationLayer() : 0))];

            srcD->lastActiveFrameSlot = dstD->lastActiveFrameSlot = currentFrameSlot;
        } else if (u.type == QRhiResourceUpdateBatchPrivate::TextureOp::Read) {
            QRhiMetalData::TextureReadback readback;
            readback.activeFrameSlot = currentFrameSlot;
            readback.desc = u.rb;
            readback.result = u.result;

            QMetalTexture *texD = QRHI_RES(QMetalTexture, u.rb.texture());
            QMetalSwapChain *swapChainD = nullptr;
            id<MTLTexture> src;
            QSize srcSize;
            bool is3D = false;
            if (texD) {
                if (texD->samples > 1) {
                    qWarning("Multisample texture cannot be read back");
                    continue;
                }
                is3D = texD->m_flags.testFlag(QRhiTexture::ThreeDimensional);
                readback.pixelSize = q->sizeForMipLevel(u.rb.level(), texD->m_pixelSize);
                readback.format = texD->m_format;
                src = texD->d->tex;
                srcSize = readback.pixelSize;
                texD->lastActiveFrameSlot = currentFrameSlot;
            } else {
                Q_ASSERT(currentSwapChain);
                swapChainD = QRHI_RES(QMetalSwapChain, currentSwapChain);
                readback.pixelSize = swapChainD->pixelSize;
                readback.format = swapChainD->d->rhiColorFormat;
                // Multisample swapchains need nothing special since resolving
                // happens when ending a renderpass.
                const QMetalRenderTargetData::ColorAtt &colorAtt(swapChainD->rtWrapper.d->fb.colorAtt[0]);
                src = colorAtt.resolveTex ? colorAtt.resolveTex : colorAtt.tex;
                srcSize = swapChainD->rtWrapper.d->pixelSize;
            }

            quint32 bpl = 0;
            textureFormatInfo(readback.format, readback.pixelSize, &bpl, &readback.bufSize, nullptr);
            readback.buf = [d->dev newBufferWithLength: readback.bufSize options: MTLResourceStorageModeShared];

            ensureBlit();
            [blitEnc copyFromTexture: src
                                      sourceSlice: NSUInteger(is3D ? 0 : u.rb.layer())
                                      sourceLevel: NSUInteger(u.rb.level())
                                      sourceOrigin: MTLOriginMake(0, 0, is3D ? u.rb.layer() : 0)
                                      sourceSize: MTLSizeMake(NSUInteger(srcSize.width()), NSUInteger(srcSize.height()), 1)
                                      toBuffer: readback.buf
                                      destinationOffset: 0
                                      destinationBytesPerRow: bpl
                                      destinationBytesPerImage: 0
                                      options: MTLBlitOptionNone];

            d->activeTextureReadbacks.append(readback);
        } else if (u.type == QRhiResourceUpdateBatchPrivate::TextureOp::GenMips) {
            QMetalTexture *utexD = QRHI_RES(QMetalTexture, u.dst);
            ensureBlit();
            [blitEnc generateMipmapsForTexture: utexD->d->tex];
            utexD->lastActiveFrameSlot = currentFrameSlot;
        }
    }

    if (blitEnc) {
        if (debugMarkers)
            [blitEnc popDebugGroup];
        [blitEnc endEncoding];
    }

    ud->free();
}

// this handles all types of buffers, not just Dynamic
void QRhiMetal::executeBufferHostWritesForSlot(QMetalBuffer *bufD, int slot)
{
    if (bufD->d->pendingUpdates[slot].isEmpty())
        return;

    void *p = [bufD->d->buf[slot] contents];
    quint32 changeBegin = UINT32_MAX;
    quint32 changeEnd = 0;
    for (const QMetalBufferData::BufferUpdate &u : std::as_const(bufD->d->pendingUpdates[slot])) {
        memcpy(static_cast<char *>(p) + u.offset, u.data.constData(), size_t(u.data.size()));
        if (u.offset < changeBegin)
            changeBegin = u.offset;
        if (u.offset + u.data.size() > changeEnd)
            changeEnd = u.offset + u.data.size();
    }
#ifdef Q_OS_MACOS
    if (changeBegin < UINT32_MAX && changeBegin < changeEnd && bufD->d->managed)
        [bufD->d->buf[slot] didModifyRange: NSMakeRange(NSUInteger(changeBegin), NSUInteger(changeEnd - changeBegin))];
#endif

    bufD->d->pendingUpdates[slot].clear();
}

void QRhiMetal::executeBufferHostWritesForCurrentFrame(QMetalBuffer *bufD)
{
    executeBufferHostWritesForSlot(bufD, bufD->d->slotted ? currentFrameSlot : 0);
}

void QRhiMetal::resourceUpdate(QRhiCommandBuffer *cb, QRhiResourceUpdateBatch *resourceUpdates)
{
    Q_ASSERT(QRHI_RES(QMetalCommandBuffer, cb)->recordingPass == QMetalCommandBuffer::NoPass);

    enqueueResourceUpdates(cb, resourceUpdates);
}

void QRhiMetal::beginPass(QRhiCommandBuffer *cb,
                          QRhiRenderTarget *rt,
                          const QColor &colorClearValue,
                          const QRhiDepthStencilClearValue &depthStencilClearValue,
                          QRhiResourceUpdateBatch *resourceUpdates,
                          QRhiCommandBuffer::BeginPassFlags)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::NoPass);

    if (resourceUpdates)
        enqueueResourceUpdates(cb, resourceUpdates);

    QMetalRenderTargetData *rtD = nullptr;
    switch (rt->resourceType()) {
    case QRhiResource::SwapChainRenderTarget:
        rtD = QRHI_RES(QMetalSwapChainRenderTarget, rt)->d;
        cbD->d->currentPassRpDesc = d->createDefaultRenderPass(rtD->dsAttCount, colorClearValue, depthStencilClearValue, rtD->colorAttCount);
        if (rtD->colorAttCount) {
            QMetalRenderTargetData::ColorAtt &color0(rtD->fb.colorAtt[0]);
            if (color0.needsDrawableForTex || color0.needsDrawableForResolveTex) {
                Q_ASSERT(currentSwapChain);
                QMetalSwapChain *swapChainD = QRHI_RES(QMetalSwapChain, currentSwapChain);
                if (!swapChainD->d->curDrawable) {
                    QMacAutoReleasePool pool;
                    swapChainD->d->curDrawable = [[swapChainD->d->layer nextDrawable] retain];
                }
                if (!swapChainD->d->curDrawable) {
                    qWarning("No drawable");
                    return;
                }
                id<MTLTexture> scTex = swapChainD->d->curDrawable.texture;
                if (color0.needsDrawableForTex) {
                    color0.tex = scTex;
                    color0.needsDrawableForTex = false;
                } else {
                    color0.resolveTex = scTex;
                    color0.needsDrawableForResolveTex = false;
                }
            }
        }
        break;
    case QRhiResource::TextureRenderTarget:
    {
        QMetalTextureRenderTarget *rtTex = QRHI_RES(QMetalTextureRenderTarget, rt);
        rtD = rtTex->d;
        if (!QRhiRenderTargetAttachmentTracker::isUpToDate<QMetalTexture, QMetalRenderBuffer>(rtTex->description(), rtD->currentResIdList))
            rtTex->create();
        cbD->d->currentPassRpDesc = d->createDefaultRenderPass(rtD->dsAttCount, colorClearValue, depthStencilClearValue, rtD->colorAttCount);
        if (rtTex->m_flags.testFlag(QRhiTextureRenderTarget::PreserveColorContents)) {
            for (uint i = 0; i < uint(rtD->colorAttCount); ++i)
                cbD->d->currentPassRpDesc.colorAttachments[i].loadAction = MTLLoadActionLoad;
        }
        if (rtD->dsAttCount && rtTex->m_flags.testFlag(QRhiTextureRenderTarget::PreserveDepthStencilContents)) {
            cbD->d->currentPassRpDesc.depthAttachment.loadAction = MTLLoadActionLoad;
            cbD->d->currentPassRpDesc.stencilAttachment.loadAction = MTLLoadActionLoad;
        }
        for (auto it = rtTex->m_desc.cbeginColorAttachments(), itEnd = rtTex->m_desc.cendColorAttachments();
             it != itEnd; ++it)
        {
            if (it->texture())
                QRHI_RES(QMetalTexture, it->texture())->lastActiveFrameSlot = currentFrameSlot;
            else if (it->renderBuffer())
                QRHI_RES(QMetalRenderBuffer, it->renderBuffer())->lastActiveFrameSlot = currentFrameSlot;
            if (it->resolveTexture())
                QRHI_RES(QMetalTexture, it->resolveTexture())->lastActiveFrameSlot = currentFrameSlot;
        }
        if (rtTex->m_desc.depthStencilBuffer())
            QRHI_RES(QMetalRenderBuffer, rtTex->m_desc.depthStencilBuffer())->lastActiveFrameSlot = currentFrameSlot;
        if (rtTex->m_desc.depthTexture())
            QRHI_RES(QMetalTexture, rtTex->m_desc.depthTexture())->lastActiveFrameSlot = currentFrameSlot;
    }
        break;
    default:
        Q_UNREACHABLE();
        break;
    }

    for (uint i = 0; i < uint(rtD->colorAttCount); ++i) {
        cbD->d->currentPassRpDesc.colorAttachments[i].texture = rtD->fb.colorAtt[i].tex;
        cbD->d->currentPassRpDesc.colorAttachments[i].slice = NSUInteger(rtD->fb.colorAtt[i].arrayLayer);
        cbD->d->currentPassRpDesc.colorAttachments[i].depthPlane = NSUInteger(rtD->fb.colorAtt[i].slice);
        cbD->d->currentPassRpDesc.colorAttachments[i].level = NSUInteger(rtD->fb.colorAtt[i].level);
        if (rtD->fb.colorAtt[i].resolveTex) {
            cbD->d->currentPassRpDesc.colorAttachments[i].storeAction = MTLStoreActionMultisampleResolve;
            cbD->d->currentPassRpDesc.colorAttachments[i].resolveTexture = rtD->fb.colorAtt[i].resolveTex;
            cbD->d->currentPassRpDesc.colorAttachments[i].resolveSlice = NSUInteger(rtD->fb.colorAtt[i].resolveLayer);
            cbD->d->currentPassRpDesc.colorAttachments[i].resolveLevel = NSUInteger(rtD->fb.colorAtt[i].resolveLevel);
        }
    }

    if (rtD->dsAttCount) {
        Q_ASSERT(rtD->fb.dsTex);
        cbD->d->currentPassRpDesc.depthAttachment.texture = rtD->fb.dsTex;
        cbD->d->currentPassRpDesc.stencilAttachment.texture = rtD->fb.hasStencil ? rtD->fb.dsTex : nil;
        if (rtD->fb.depthNeedsStore) // Depth/Stencil is set to DontCare by default, override if  needed
            cbD->d->currentPassRpDesc.depthAttachment.storeAction = MTLStoreActionStore;
    }

    cbD->d->currentRenderPassEncoder = [cbD->d->cb renderCommandEncoderWithDescriptor: cbD->d->currentPassRpDesc];

    cbD->resetPerPassState();

    cbD->recordingPass = QMetalCommandBuffer::RenderPass;
    cbD->currentTarget = rt;
}

void QRhiMetal::endPass(QRhiCommandBuffer *cb, QRhiResourceUpdateBatch *resourceUpdates)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::RenderPass);

    [cbD->d->currentRenderPassEncoder endEncoding];

    cbD->recordingPass = QMetalCommandBuffer::NoPass;
    cbD->currentTarget = nullptr;

    if (resourceUpdates)
        enqueueResourceUpdates(cb, resourceUpdates);
}

void QRhiMetal::beginComputePass(QRhiCommandBuffer *cb,
                                 QRhiResourceUpdateBatch *resourceUpdates,
                                 QRhiCommandBuffer::BeginPassFlags)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::NoPass);

    if (resourceUpdates)
        enqueueResourceUpdates(cb, resourceUpdates);

    cbD->d->currentComputePassEncoder = [cbD->d->cb computeCommandEncoder];
    cbD->resetPerPassState();
    cbD->recordingPass = QMetalCommandBuffer::ComputePass;
}

void QRhiMetal::endComputePass(QRhiCommandBuffer *cb, QRhiResourceUpdateBatch *resourceUpdates)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::ComputePass);

    [cbD->d->currentComputePassEncoder endEncoding];
    cbD->recordingPass = QMetalCommandBuffer::NoPass;

    if (resourceUpdates)
        enqueueResourceUpdates(cb, resourceUpdates);
}

void QRhiMetal::setComputePipeline(QRhiCommandBuffer *cb, QRhiComputePipeline *ps)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::ComputePass);
    QMetalComputePipeline *psD = QRHI_RES(QMetalComputePipeline, ps);

    if (cbD->currentComputePipeline != psD || cbD->currentPipelineGeneration != psD->generation) {
        cbD->currentGraphicsPipeline = nullptr;
        cbD->currentComputePipeline = psD;
        cbD->currentPipelineGeneration = psD->generation;

        [cbD->d->currentComputePassEncoder setComputePipelineState: psD->d->ps];
    }

    psD->lastActiveFrameSlot = currentFrameSlot;
}

void QRhiMetal::dispatch(QRhiCommandBuffer *cb, int x, int y, int z)
{
    QMetalCommandBuffer *cbD = QRHI_RES(QMetalCommandBuffer, cb);
    Q_ASSERT(cbD->recordingPass == QMetalCommandBuffer::ComputePass);
    QMetalComputePipeline *psD = QRHI_RES(QMetalComputePipeline, cbD->currentComputePipeline);

    [cbD->d->currentComputePassEncoder dispatchThreadgroups: MTLSizeMake(NSUInteger(x), NSUInteger(y), NSUInteger(z))
      threadsPerThreadgroup: psD->d->localSize];
}

static void qrhimtl_releaseBuffer(const QRhiMetalData::DeferredReleaseEntry &e)
{
    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i)
        [e.buffer.buffers[i] release];
}

static void qrhimtl_releaseRenderBuffer(const QRhiMetalData::DeferredReleaseEntry &e)
{
    [e.renderbuffer.texture release];
}

static void qrhimtl_releaseTexture(const QRhiMetalData::DeferredReleaseEntry &e)
{
    [e.texture.texture release];
    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i)
        [e.texture.stagingBuffers[i] release];
    for (int i = 0; i < QRhi::MAX_MIP_LEVELS; ++i)
        [e.texture.views[i] release];
}

static void qrhimtl_releaseSampler(const QRhiMetalData::DeferredReleaseEntry &e)
{
    [e.sampler.samplerState release];
}

void QRhiMetal::executeDeferredReleases(bool forced)
{
    for (int i = d->releaseQueue.count() - 1; i >= 0; --i) {
        const QRhiMetalData::DeferredReleaseEntry &e(d->releaseQueue[i]);
        if (forced || currentFrameSlot == e.lastActiveFrameSlot || e.lastActiveFrameSlot < 0) {
            switch (e.type) {
            case QRhiMetalData::DeferredReleaseEntry::Buffer:
                qrhimtl_releaseBuffer(e);
                break;
            case QRhiMetalData::DeferredReleaseEntry::RenderBuffer:
                qrhimtl_releaseRenderBuffer(e);
                break;
            case QRhiMetalData::DeferredReleaseEntry::Texture:
                qrhimtl_releaseTexture(e);
                break;
            case QRhiMetalData::DeferredReleaseEntry::Sampler:
                qrhimtl_releaseSampler(e);
                break;
            case QRhiMetalData::DeferredReleaseEntry::StagingBuffer:
                [e.stagingBuffer.buffer release];
                break;
            case QRhiMetalData::DeferredReleaseEntry::GraphicsPipeline:
                [e.graphicsPipeline.pipelineState release];
                [e.graphicsPipeline.depthStencilState release];
                [e.graphicsPipeline.tessVertexComputeState[0] release];
                [e.graphicsPipeline.tessVertexComputeState[1] release];
                [e.graphicsPipeline.tessVertexComputeState[2] release];
                [e.graphicsPipeline.tessTessControlComputeState release];
                break;
            case QRhiMetalData::DeferredReleaseEntry::ComputePipeline:
                [e.computePipeline.pipelineState release];
                break;
            default:
                break;
            }
            d->releaseQueue.removeAt(i);
        }
    }
}

void QRhiMetal::finishActiveReadbacks(bool forced)
{
    QVarLengthArray<std::function<void()>, 4> completedCallbacks;

    for (int i = d->activeTextureReadbacks.count() - 1; i >= 0; --i) {
        const QRhiMetalData::TextureReadback &readback(d->activeTextureReadbacks[i]);
        if (forced || currentFrameSlot == readback.activeFrameSlot || readback.activeFrameSlot < 0) {
            readback.result->format = readback.format;
            readback.result->pixelSize = readback.pixelSize;
            readback.result->data.resize(int(readback.bufSize));
            void *p = [readback.buf contents];
            memcpy(readback.result->data.data(), p, readback.bufSize);
            [readback.buf release];

            if (readback.result->completed)
                completedCallbacks.append(readback.result->completed);

            d->activeTextureReadbacks.remove(i);
        }
    }

    for (int i = d->activeBufferReadbacks.count() - 1; i >= 0; --i) {
        const QRhiMetalData::BufferReadback &readback(d->activeBufferReadbacks[i]);
        if (forced || currentFrameSlot == readback.activeFrameSlot
                || readback.activeFrameSlot < 0) {
            readback.result->data.resize(readback.readSize);
            char *p = reinterpret_cast<char *>([readback.buf contents]);
            Q_ASSERT(p);
            memcpy(readback.result->data.data(), p + readback.offset, size_t(readback.readSize));

            if (readback.result->completed)
                completedCallbacks.append(readback.result->completed);

            d->activeBufferReadbacks.remove(i);
        }
    }

    for (auto f : completedCallbacks)
        f();
}

QMetalBuffer::QMetalBuffer(QRhiImplementation *rhi, Type type, UsageFlags usage, quint32 size)
    : QRhiBuffer(rhi, type, usage, size),
      d(new QMetalBufferData)
{
    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i)
        d->buf[i] = nil;
}

QMetalBuffer::~QMetalBuffer()
{
    destroy();
    delete d;
}

void QMetalBuffer::destroy()
{
    if (!d->buf[0])
        return;

    QRhiMetalData::DeferredReleaseEntry e;
    e.type = QRhiMetalData::DeferredReleaseEntry::Buffer;
    e.lastActiveFrameSlot = lastActiveFrameSlot;

    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
        e.buffer.buffers[i] = d->buf[i];
        d->buf[i] = nil;
        d->pendingUpdates[i].clear();
    }

    QRHI_RES_RHI(QRhiMetal);
    if (rhiD) {
        rhiD->d->releaseQueue.append(e);
        rhiD->unregisterResource(this);
    }
}

bool QMetalBuffer::create()
{
    if (d->buf[0])
        destroy();

    if (m_usage.testFlag(QRhiBuffer::StorageBuffer) && m_type == Dynamic) {
        qWarning("StorageBuffer cannot be combined with Dynamic");
        return false;
    }

    const quint32 nonZeroSize = m_size <= 0 ? 256 : m_size;
    const quint32 roundedSize = m_usage.testFlag(QRhiBuffer::UniformBuffer) ? aligned(nonZeroSize, 256u) : nonZeroSize;

    d->managed = false;
    MTLResourceOptions opts = MTLResourceStorageModeShared;

    QRHI_RES_RHI(QRhiMetal);
#ifdef Q_OS_MACOS
    if (!rhiD->caps.isAppleGPU && m_type != Dynamic) {
        opts = MTLResourceStorageModeManaged;
        d->managed = true;
    }
#endif

    // Have QMTL_FRAMES_IN_FLIGHT versions regardless of the type, for now.
    // This is because writing to a Managed buffer (which is what Immutable and
    // Static maps to on macOS) is not safe when another frame reading from the
    // same buffer is still in flight.
    d->slotted = !m_usage.testFlag(QRhiBuffer::StorageBuffer); // except for SSBOs written in the shader
    // and a special case for internal work buffers
    if (int(m_usage) == WorkBufPoolUsage)
        d->slotted = false;

    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
        if (i == 0 || d->slotted) {
            d->buf[i] = [rhiD->d->dev newBufferWithLength: roundedSize options: opts];
            if (!m_objectName.isEmpty()) {
                if (!d->slotted) {
                    d->buf[i].label = [NSString stringWithUTF8String: m_objectName.constData()];
                } else {
                    const QByteArray name = m_objectName + '/' + QByteArray::number(i);
                    d->buf[i].label = [NSString stringWithUTF8String: name.constData()];
                }
            }
        }
    }

    lastActiveFrameSlot = -1;
    generation += 1;
    rhiD->registerResource(this);
    return true;
}

QRhiBuffer::NativeBuffer QMetalBuffer::nativeBuffer()
{
    if (d->slotted) {
        NativeBuffer b;
        Q_ASSERT(sizeof(b.objects) / sizeof(b.objects[0]) >= size_t(QMTL_FRAMES_IN_FLIGHT));
        for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
            QRHI_RES_RHI(QRhiMetal);
            rhiD->executeBufferHostWritesForSlot(this, i);
            b.objects[i] = &d->buf[i];
        }
        b.slotCount = QMTL_FRAMES_IN_FLIGHT;
        return b;
    }
    return { { &d->buf[0] }, 1 };
}

char *QMetalBuffer::beginFullDynamicBufferUpdateForCurrentFrame()
{
    // Shortcut the entire buffer update mechanism and allow the client to do
    // the host writes directly to the buffer. This will lead to unexpected
    // results when combined with QRhiResourceUpdateBatch-based updates for the
    // buffer, but provides a fast path for dynamic buffers that have all their
    // content changed in every frame.
    Q_ASSERT(m_type == Dynamic);
    QRHI_RES_RHI(QRhiMetal);
    Q_ASSERT(rhiD->inFrame);
    const int slot = rhiD->currentFrameSlot;
    void *p = [d->buf[slot] contents];
    return static_cast<char *>(p);
}

void QMetalBuffer::endFullDynamicBufferUpdateForCurrentFrame()
{
#ifdef Q_OS_MACOS
    if (d->managed) {
        QRHI_RES_RHI(QRhiMetal);
        const int slot = rhiD->currentFrameSlot;
        [d->buf[slot] didModifyRange: NSMakeRange(0, NSUInteger(m_size))];
    }
#endif
}

static inline MTLPixelFormat toMetalTextureFormat(QRhiTexture::Format format, QRhiTexture::Flags flags, const QRhiMetal *d)
{
#ifndef Q_OS_MACOS
    Q_UNUSED(d);
#endif

    const bool srgb = flags.testFlag(QRhiTexture::sRGB);
    switch (format) {
    case QRhiTexture::RGBA8:
        return srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
    case QRhiTexture::BGRA8:
        return srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
    case QRhiTexture::R8:
#ifdef Q_OS_MACOS
        return MTLPixelFormatR8Unorm;
#else
        return srgb ? MTLPixelFormatR8Unorm_sRGB : MTLPixelFormatR8Unorm;
#endif
    case QRhiTexture::RG8:
#ifdef Q_OS_MACOS
        return MTLPixelFormatRG8Unorm;
#else
        return srgb ? MTLPixelFormatRG8Unorm_sRGB : MTLPixelFormatRG8Unorm;
#endif
    case QRhiTexture::R16:
        return MTLPixelFormatR16Unorm;
    case QRhiTexture::RG16:
        return MTLPixelFormatRG16Unorm;
    case QRhiTexture::RED_OR_ALPHA8:
        return MTLPixelFormatR8Unorm;

    case QRhiTexture::RGBA16F:
        return MTLPixelFormatRGBA16Float;
    case QRhiTexture::RGBA32F:
        return MTLPixelFormatRGBA32Float;
    case QRhiTexture::R16F:
        return MTLPixelFormatR16Float;
    case QRhiTexture::R32F:
        return MTLPixelFormatR32Float;

    case QRhiTexture::RGB10A2:
        return MTLPixelFormatRGB10A2Unorm;

#ifdef Q_OS_MACOS
    case QRhiTexture::D16:
        return MTLPixelFormatDepth16Unorm;
    case QRhiTexture::D24:
        return [d->d->dev isDepth24Stencil8PixelFormatSupported] ? MTLPixelFormatDepth24Unorm_Stencil8 : MTLPixelFormatDepth32Float;
    case QRhiTexture::D24S8:
        return [d->d->dev isDepth24Stencil8PixelFormatSupported] ? MTLPixelFormatDepth24Unorm_Stencil8 : MTLPixelFormatDepth32Float_Stencil8;
#else
    case QRhiTexture::D16:
        return MTLPixelFormatDepth32Float;
    case QRhiTexture::D24:
        return MTLPixelFormatDepth32Float;
    case QRhiTexture::D24S8:
        return MTLPixelFormatDepth32Float_Stencil8;
#endif
    case QRhiTexture::D32F:
        return MTLPixelFormatDepth32Float;

#ifdef Q_OS_MACOS
    case QRhiTexture::BC1:
        return srgb ? MTLPixelFormatBC1_RGBA_sRGB : MTLPixelFormatBC1_RGBA;
    case QRhiTexture::BC2:
        return srgb ? MTLPixelFormatBC2_RGBA_sRGB : MTLPixelFormatBC2_RGBA;
    case QRhiTexture::BC3:
        return srgb ? MTLPixelFormatBC3_RGBA_sRGB : MTLPixelFormatBC3_RGBA;
    case QRhiTexture::BC4:
        return MTLPixelFormatBC4_RUnorm;
    case QRhiTexture::BC5:
        qWarning("QRhiMetal does not support BC5");
        return MTLPixelFormatInvalid;
    case QRhiTexture::BC6H:
        return MTLPixelFormatBC6H_RGBUfloat;
    case QRhiTexture::BC7:
        return srgb ? MTLPixelFormatBC7_RGBAUnorm_sRGB : MTLPixelFormatBC7_RGBAUnorm;
#else
    case QRhiTexture::BC1:
    case QRhiTexture::BC2:
    case QRhiTexture::BC3:
    case QRhiTexture::BC4:
    case QRhiTexture::BC5:
    case QRhiTexture::BC6H:
    case QRhiTexture::BC7:
        qWarning("QRhiMetal: BCx compression not supported on this platform");
        return MTLPixelFormatInvalid;
#endif

#ifndef Q_OS_MACOS
    case QRhiTexture::ETC2_RGB8:
        return srgb ? MTLPixelFormatETC2_RGB8_sRGB : MTLPixelFormatETC2_RGB8;
    case QRhiTexture::ETC2_RGB8A1:
        return srgb ? MTLPixelFormatETC2_RGB8A1_sRGB : MTLPixelFormatETC2_RGB8A1;
    case QRhiTexture::ETC2_RGBA8:
        return srgb ? MTLPixelFormatEAC_RGBA8_sRGB : MTLPixelFormatEAC_RGBA8;

    case QRhiTexture::ASTC_4x4:
        return srgb ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR;
    case QRhiTexture::ASTC_5x4:
        return srgb ? MTLPixelFormatASTC_5x4_sRGB : MTLPixelFormatASTC_5x4_LDR;
    case QRhiTexture::ASTC_5x5:
        return srgb ? MTLPixelFormatASTC_5x5_sRGB : MTLPixelFormatASTC_5x5_LDR;
    case QRhiTexture::ASTC_6x5:
        return srgb ? MTLPixelFormatASTC_6x5_sRGB : MTLPixelFormatASTC_6x5_LDR;
    case QRhiTexture::ASTC_6x6:
        return srgb ? MTLPixelFormatASTC_6x6_sRGB : MTLPixelFormatASTC_6x6_LDR;
    case QRhiTexture::ASTC_8x5:
        return srgb ? MTLPixelFormatASTC_8x5_sRGB : MTLPixelFormatASTC_8x5_LDR;
    case QRhiTexture::ASTC_8x6:
        return srgb ? MTLPixelFormatASTC_8x6_sRGB : MTLPixelFormatASTC_8x6_LDR;
    case QRhiTexture::ASTC_8x8:
        return srgb ? MTLPixelFormatASTC_8x8_sRGB : MTLPixelFormatASTC_8x8_LDR;
    case QRhiTexture::ASTC_10x5:
        return srgb ? MTLPixelFormatASTC_10x5_sRGB : MTLPixelFormatASTC_10x5_LDR;
    case QRhiTexture::ASTC_10x6:
        return srgb ? MTLPixelFormatASTC_10x6_sRGB : MTLPixelFormatASTC_10x6_LDR;
    case QRhiTexture::ASTC_10x8:
        return srgb ? MTLPixelFormatASTC_10x8_sRGB : MTLPixelFormatASTC_10x8_LDR;
    case QRhiTexture::ASTC_10x10:
        return srgb ? MTLPixelFormatASTC_10x10_sRGB : MTLPixelFormatASTC_10x10_LDR;
    case QRhiTexture::ASTC_12x10:
        return srgb ? MTLPixelFormatASTC_12x10_sRGB : MTLPixelFormatASTC_12x10_LDR;
    case QRhiTexture::ASTC_12x12:
        return srgb ? MTLPixelFormatASTC_12x12_sRGB : MTLPixelFormatASTC_12x12_LDR;
#else
    case QRhiTexture::ETC2_RGB8:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatETC2_RGB8_sRGB : MTLPixelFormatETC2_RGB8;
        }
        qWarning("QRhiMetal: ETC2 compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ETC2_RGB8A1:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatETC2_RGB8A1_sRGB : MTLPixelFormatETC2_RGB8A1;
        }
        qWarning("QRhiMetal: ETC2 compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ETC2_RGBA8:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatEAC_RGBA8_sRGB : MTLPixelFormatEAC_RGBA8;
        }
        qWarning("QRhiMetal: ETC2 compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_4x4:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_5x4:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_5x4_sRGB : MTLPixelFormatASTC_5x4_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_5x5:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_5x5_sRGB : MTLPixelFormatASTC_5x5_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_6x5:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_6x5_sRGB : MTLPixelFormatASTC_6x5_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_6x6:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_6x6_sRGB : MTLPixelFormatASTC_6x6_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_8x5:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_8x5_sRGB : MTLPixelFormatASTC_8x5_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_8x6:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_8x6_sRGB : MTLPixelFormatASTC_8x6_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_8x8:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_8x8_sRGB : MTLPixelFormatASTC_8x8_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_10x5:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_10x5_sRGB : MTLPixelFormatASTC_10x5_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_10x6:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_10x6_sRGB : MTLPixelFormatASTC_10x6_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_10x8:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_10x8_sRGB : MTLPixelFormatASTC_10x8_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_10x10:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_10x10_sRGB : MTLPixelFormatASTC_10x10_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_12x10:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_12x10_sRGB : MTLPixelFormatASTC_12x10_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
    case QRhiTexture::ASTC_12x12:
        if (d->caps.isAppleGPU) {
            if (@available(macOS 11.0, *))
                return srgb ? MTLPixelFormatASTC_12x12_sRGB : MTLPixelFormatASTC_12x12_LDR;
        }
        qWarning("QRhiMetal: ASTC compression not supported on this platform");
        return MTLPixelFormatInvalid;
#endif

    default:
        Q_UNREACHABLE();
        return MTLPixelFormatInvalid;
    }
}

QMetalRenderBuffer::QMetalRenderBuffer(QRhiImplementation *rhi, Type type, const QSize &pixelSize,
                                       int sampleCount, QRhiRenderBuffer::Flags flags,
                                       QRhiTexture::Format backingFormatHint)
    : QRhiRenderBuffer(rhi, type, pixelSize, sampleCount, flags, backingFormatHint),
      d(new QMetalRenderBufferData)
{
}

QMetalRenderBuffer::~QMetalRenderBuffer()
{
    destroy();
    delete d;
}

void QMetalRenderBuffer::destroy()
{
    if (!d->tex)
        return;

    QRhiMetalData::DeferredReleaseEntry e;
    e.type = QRhiMetalData::DeferredReleaseEntry::RenderBuffer;
    e.lastActiveFrameSlot = lastActiveFrameSlot;

    e.renderbuffer.texture = d->tex;
    d->tex = nil;

    QRHI_RES_RHI(QRhiMetal);
    if (rhiD) {
        rhiD->d->releaseQueue.append(e);
        rhiD->unregisterResource(this);
    }
}

bool QMetalRenderBuffer::create()
{
    if (d->tex)
        destroy();

    if (m_pixelSize.isEmpty())
        return false;

    QRHI_RES_RHI(QRhiMetal);
    samples = rhiD->effectiveSampleCount(m_sampleCount);

    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
    desc.width = NSUInteger(m_pixelSize.width());
    desc.height = NSUInteger(m_pixelSize.height());
    if (samples > 1)
        desc.sampleCount = NSUInteger(samples);
    desc.resourceOptions = MTLResourceStorageModePrivate;
    desc.usage = MTLTextureUsageRenderTarget;

    switch (m_type) {
    case DepthStencil:
#ifdef Q_OS_MACOS
        if (rhiD->caps.isAppleGPU) {
            if (@available(macOS 11.0, *)) {
                desc.storageMode = MTLStorageModeMemoryless;
                d->format = MTLPixelFormatDepth32Float_Stencil8;
            } else {
                Q_UNREACHABLE();
            }
        } else {
            desc.storageMode = MTLStorageModePrivate;
            d->format = rhiD->d->dev.depth24Stencil8PixelFormatSupported
                    ? MTLPixelFormatDepth24Unorm_Stencil8 : MTLPixelFormatDepth32Float_Stencil8;
        }
#else
        desc.storageMode = MTLStorageModeMemoryless;
        d->format = MTLPixelFormatDepth32Float_Stencil8;
#endif
        desc.pixelFormat = d->format;
        break;
    case Color:
        desc.storageMode = MTLStorageModePrivate;
        if (m_backingFormatHint != QRhiTexture::UnknownFormat)
            d->format = toMetalTextureFormat(m_backingFormatHint, {}, rhiD);
        else
            d->format = MTLPixelFormatRGBA8Unorm;
        desc.pixelFormat = d->format;
        break;
    default:
        Q_UNREACHABLE();
        break;
    }

    d->tex = [rhiD->d->dev newTextureWithDescriptor: desc];
    [desc release];

    if (!m_objectName.isEmpty())
        d->tex.label = [NSString stringWithUTF8String: m_objectName.constData()];

    lastActiveFrameSlot = -1;
    generation += 1;
    rhiD->registerResource(this);
    return true;
}

QRhiTexture::Format QMetalRenderBuffer::backingFormat() const
{
    if (m_backingFormatHint != QRhiTexture::UnknownFormat)
        return m_backingFormatHint;
    else
        return m_type == Color ? QRhiTexture::RGBA8 : QRhiTexture::UnknownFormat;
}

QMetalTexture::QMetalTexture(QRhiImplementation *rhi, Format format, const QSize &pixelSize, int depth,
                             int arraySize, int sampleCount, Flags flags)
    : QRhiTexture(rhi, format, pixelSize, depth, arraySize, sampleCount, flags),
      d(new QMetalTextureData(this))
{
    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i)
        d->stagingBuf[i] = nil;

    for (int i = 0; i < QRhi::MAX_MIP_LEVELS; ++i)
        d->perLevelViews[i] = nil;
}

QMetalTexture::~QMetalTexture()
{
    destroy();
    delete d;
}

void QMetalTexture::destroy()
{
    if (!d->tex)
        return;

    QRhiMetalData::DeferredReleaseEntry e;
    e.type = QRhiMetalData::DeferredReleaseEntry::Texture;
    e.lastActiveFrameSlot = lastActiveFrameSlot;

    e.texture.texture = d->owns ? d->tex : nil;
    d->tex = nil;

    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
        e.texture.stagingBuffers[i] = d->stagingBuf[i];
        d->stagingBuf[i] = nil;
    }

    for (int i = 0; i < QRhi::MAX_MIP_LEVELS; ++i) {
        e.texture.views[i] = d->perLevelViews[i];
        d->perLevelViews[i] = nil;
    }

    QRHI_RES_RHI(QRhiMetal);
    if (rhiD) {
        rhiD->d->releaseQueue.append(e);
        rhiD->unregisterResource(this);
    }
}

bool QMetalTexture::prepareCreate(QSize *adjustedSize)
{
    if (d->tex)
        destroy();

    const bool isCube = m_flags.testFlag(CubeMap);
    const bool is3D = m_flags.testFlag(ThreeDimensional);
    const bool isArray = m_flags.testFlag(TextureArray);
    const bool hasMipMaps = m_flags.testFlag(MipMapped);
    const bool is1D = m_flags.testFlag(OneDimensional);

    const QSize size = is1D ? QSize(qMax(1, m_pixelSize.width()), 1)
                            : (m_pixelSize.isEmpty() ? QSize(1, 1) : m_pixelSize);

    QRHI_RES_RHI(QRhiMetal);
    d->format = toMetalTextureFormat(m_format, m_flags, rhiD);
    mipLevelCount = hasMipMaps ? rhiD->q->mipLevelsForSize(size) : 1;
    samples = rhiD->effectiveSampleCount(m_sampleCount);
    if (samples > 1) {
        if (isCube) {
            qWarning("Cubemap texture cannot be multisample");
            return false;
        }
        if (is3D) {
            qWarning("3D texture cannot be multisample");
            return false;
        }
        if (hasMipMaps) {
            qWarning("Multisample texture cannot have mipmaps");
            return false;
        }
    }
    if (isCube && is3D) {
        qWarning("Texture cannot be both cube and 3D");
        return false;
    }
    if (isArray && is3D) {
        qWarning("Texture cannot be both array and 3D");
        return false;
    }
    if (is1D && is3D) {
        qWarning("Texture cannot be both 1D and 3D");
        return false;
    }
    if (is1D && isCube) {
        qWarning("Texture cannot be both 1D and cube");
        return false;
    }
    m_depth = qMax(1, m_depth);
    if (m_depth > 1 && !is3D) {
        qWarning("Texture cannot have a depth of %d when it is not 3D", m_depth);
        return false;
    }
    m_arraySize = qMax(0, m_arraySize);
    if (m_arraySize > 0 && !isArray) {
        qWarning("Texture cannot have an array size of %d when it is not an array", m_arraySize);
        return false;
    }
    if (m_arraySize < 1 && isArray) {
        qWarning("Texture is an array but array size is %d", m_arraySize);
        return false;
    }

    if (adjustedSize)
        *adjustedSize = size;

    return true;
}

bool QMetalTexture::create()
{
    QSize size;
    if (!prepareCreate(&size))
        return false;

    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];

    const bool isCube = m_flags.testFlag(CubeMap);
    const bool is3D = m_flags.testFlag(ThreeDimensional);
    const bool isArray = m_flags.testFlag(TextureArray);
    const bool is1D = m_flags.testFlag(OneDimensional);
    if (isCube) {
        desc.textureType = MTLTextureTypeCube;
    } else if (is3D) {
        desc.textureType = MTLTextureType3D;
    } else if (is1D) {
        desc.textureType = isArray ? MTLTextureType1DArray : MTLTextureType1D;
    } else if (isArray) {
#ifdef Q_OS_IOS
        if (samples > 1) {
            // would be available on iOS 14.0+ but cannot test for that with a 13 SDK
            qWarning("Multisample 2D texture array is not supported on iOS");
        }
        desc.textureType = MTLTextureType2DArray;
#else
        desc.textureType = samples > 1 ? MTLTextureType2DMultisampleArray : MTLTextureType2DArray;
#endif
    } else {
        desc.textureType = samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
    }
    desc.pixelFormat = d->format;
    desc.width = NSUInteger(size.width());
    desc.height = NSUInteger(size.height());
    desc.depth = is3D ? m_depth : 1;
    desc.mipmapLevelCount = NSUInteger(mipLevelCount);
    if (samples > 1)
        desc.sampleCount = NSUInteger(samples);
    if (isArray)
        desc.arrayLength = NSUInteger(m_arraySize);
    desc.resourceOptions = MTLResourceStorageModePrivate;
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead;
    if (m_flags.testFlag(RenderTarget))
        desc.usage |= MTLTextureUsageRenderTarget;
    if (m_flags.testFlag(UsedWithLoadStore))
        desc.usage |= MTLTextureUsageShaderWrite;

    QRHI_RES_RHI(QRhiMetal);
    d->tex = [rhiD->d->dev newTextureWithDescriptor: desc];
    [desc release];

    if (!m_objectName.isEmpty())
        d->tex.label = [NSString stringWithUTF8String: m_objectName.constData()];

    d->owns = true;

    lastActiveFrameSlot = -1;
    generation += 1;
    rhiD->registerResource(this);
    return true;
}

bool QMetalTexture::createFrom(QRhiTexture::NativeTexture src)
{
    id<MTLTexture> tex = id<MTLTexture>(src.object);
    if (tex == 0)
        return false;

    if (!prepareCreate())
        return false;

    d->tex = tex;

    d->owns = false;

    lastActiveFrameSlot = -1;
    generation += 1;
    QRHI_RES_RHI(QRhiMetal);
    rhiD->registerResource(this);
    return true;
}

QRhiTexture::NativeTexture QMetalTexture::nativeTexture()
{
    return {quint64(d->tex), 0};
}

id<MTLTexture> QMetalTextureData::viewForLevel(int level)
{
    Q_ASSERT(level >= 0 && level < int(q->mipLevelCount));
    if (perLevelViews[level])
        return perLevelViews[level];

    const MTLTextureType type = [tex textureType];
    const bool isCube = q->m_flags.testFlag(QRhiTexture::CubeMap);
    const bool isArray = q->m_flags.testFlag(QRhiTexture::TextureArray);
    id<MTLTexture> view = [tex newTextureViewWithPixelFormat: format textureType: type
            levels: NSMakeRange(NSUInteger(level), 1) slices: NSMakeRange(0, isCube ? 6 : (isArray ? q->m_arraySize : 1))];

    perLevelViews[level] = view;
    return view;
}

QMetalSampler::QMetalSampler(QRhiImplementation *rhi, Filter magFilter, Filter minFilter, Filter mipmapMode,
                             AddressMode u, AddressMode v, AddressMode w)
    : QRhiSampler(rhi, magFilter, minFilter, mipmapMode, u, v, w),
      d(new QMetalSamplerData)
{
}

QMetalSampler::~QMetalSampler()
{
    destroy();
    delete d;
}

void QMetalSampler::destroy()
{
    if (!d->samplerState)
        return;

    QRhiMetalData::DeferredReleaseEntry e;
    e.type = QRhiMetalData::DeferredReleaseEntry::Sampler;
    e.lastActiveFrameSlot = lastActiveFrameSlot;

    e.sampler.samplerState = d->samplerState;
    d->samplerState = nil;

    QRHI_RES_RHI(QRhiMetal);
    if (rhiD) {
        rhiD->d->releaseQueue.append(e);
        rhiD->unregisterResource(this);
    }
}

static inline MTLSamplerMinMagFilter toMetalFilter(QRhiSampler::Filter f)
{
    switch (f) {
    case QRhiSampler::Nearest:
        return MTLSamplerMinMagFilterNearest;
    case QRhiSampler::Linear:
        return MTLSamplerMinMagFilterLinear;
    default:
        Q_UNREACHABLE();
        return MTLSamplerMinMagFilterNearest;
    }
}

static inline MTLSamplerMipFilter toMetalMipmapMode(QRhiSampler::Filter f)
{
    switch (f) {
    case QRhiSampler::None:
        return MTLSamplerMipFilterNotMipmapped;
    case QRhiSampler::Nearest:
        return MTLSamplerMipFilterNearest;
    case QRhiSampler::Linear:
        return MTLSamplerMipFilterLinear;
    default:
        Q_UNREACHABLE();
        return MTLSamplerMipFilterNotMipmapped;
    }
}

static inline MTLSamplerAddressMode toMetalAddressMode(QRhiSampler::AddressMode m)
{
    switch (m) {
    case QRhiSampler::Repeat:
        return MTLSamplerAddressModeRepeat;
    case QRhiSampler::ClampToEdge:
        return MTLSamplerAddressModeClampToEdge;
    case QRhiSampler::Mirror:
        return MTLSamplerAddressModeMirrorRepeat;
    default:
        Q_UNREACHABLE();
        return MTLSamplerAddressModeClampToEdge;
    }
}

static inline MTLCompareFunction toMetalTextureCompareFunction(QRhiSampler::CompareOp op)
{
    switch (op) {
    case QRhiSampler::Never:
        return MTLCompareFunctionNever;
    case QRhiSampler::Less:
        return MTLCompareFunctionLess;
    case QRhiSampler::Equal:
        return MTLCompareFunctionEqual;
    case QRhiSampler::LessOrEqual:
        return MTLCompareFunctionLessEqual;
    case QRhiSampler::Greater:
        return MTLCompareFunctionGreater;
    case QRhiSampler::NotEqual:
        return MTLCompareFunctionNotEqual;
    case QRhiSampler::GreaterOrEqual:
        return MTLCompareFunctionGreaterEqual;
    case QRhiSampler::Always:
        return MTLCompareFunctionAlways;
    default:
        Q_UNREACHABLE();
        return MTLCompareFunctionNever;
    }
}

bool QMetalSampler::create()
{
    if (d->samplerState)
        destroy();

    MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];
    desc.minFilter = toMetalFilter(m_minFilter);
    desc.magFilter = toMetalFilter(m_magFilter);
    desc.mipFilter = toMetalMipmapMode(m_mipmapMode);
    desc.sAddressMode = toMetalAddressMode(m_addressU);
    desc.tAddressMode = toMetalAddressMode(m_addressV);
    desc.rAddressMode = toMetalAddressMode(m_addressW);
    desc.compareFunction = toMetalTextureCompareFunction(m_compareOp);

    QRHI_RES_RHI(QRhiMetal);
    d->samplerState = [rhiD->d->dev newSamplerStateWithDescriptor: desc];
    [desc release];

    lastActiveFrameSlot = -1;
    generation += 1;
    rhiD->registerResource(this);
    return true;
}

// dummy, no Vulkan-style RenderPass+Framebuffer concept here.
// We do have MTLRenderPassDescriptor of course, but it will be created on the fly for each pass.
QMetalRenderPassDescriptor::QMetalRenderPassDescriptor(QRhiImplementation *rhi)
    : QRhiRenderPassDescriptor(rhi)
{
    serializedFormatData.reserve(16);
}

QMetalRenderPassDescriptor::~QMetalRenderPassDescriptor()
{
    destroy();
}

void QMetalRenderPassDescriptor::destroy()
{
    // nothing to do here
}

bool QMetalRenderPassDescriptor::isCompatible(const QRhiRenderPassDescriptor *other) const
{
    if (!other)
        return false;

    const QMetalRenderPassDescriptor *o = QRHI_RES(const QMetalRenderPassDescriptor, other);

    if (colorAttachmentCount != o->colorAttachmentCount)
        return false;

    if (hasDepthStencil != o->hasDepthStencil)
         return false;

    for (int i = 0; i < colorAttachmentCount; ++i) {
        if (colorFormat[i] != o->colorFormat[i])
            return false;
    }

    if (hasDepthStencil) {
        if (dsFormat != o->dsFormat)
            return false;
    }

    return true;
}

void QMetalRenderPassDescriptor::updateSerializedFormat()
{
    serializedFormatData.clear();
    auto p = std::back_inserter(serializedFormatData);

    *p++ = colorAttachmentCount;
    *p++ = hasDepthStencil;
    for (int i = 0; i < colorAttachmentCount; ++i)
      *p++ = colorFormat[i];
    *p++ = hasDepthStencil ? dsFormat : 0;
}

QRhiRenderPassDescriptor *QMetalRenderPassDescriptor::newCompatibleRenderPassDescriptor() const
{
    QMetalRenderPassDescriptor *rp = new QMetalRenderPassDescriptor(m_rhi);
    rp->colorAttachmentCount = colorAttachmentCount;
    rp->hasDepthStencil = hasDepthStencil;
    memcpy(rp->colorFormat, colorFormat, sizeof(colorFormat));
    rp->dsFormat = dsFormat;
    rp->updateSerializedFormat();
    return rp;
}

QVector<quint32> QMetalRenderPassDescriptor::serializedFormat() const
{
    return serializedFormatData;
}

QMetalSwapChainRenderTarget::QMetalSwapChainRenderTarget(QRhiImplementation *rhi, QRhiSwapChain *swapchain)
    : QRhiSwapChainRenderTarget(rhi, swapchain),
      d(new QMetalRenderTargetData)
{
}

QMetalSwapChainRenderTarget::~QMetalSwapChainRenderTarget()
{
    destroy();
    delete d;
}

void QMetalSwapChainRenderTarget::destroy()
{
    // nothing to do here
}

QSize QMetalSwapChainRenderTarget::pixelSize() const
{
    return d->pixelSize;
}

float QMetalSwapChainRenderTarget::devicePixelRatio() const
{
    return d->dpr;
}

int QMetalSwapChainRenderTarget::sampleCount() const
{
    return d->sampleCount;
}

QMetalTextureRenderTarget::QMetalTextureRenderTarget(QRhiImplementation *rhi,
                                                     const QRhiTextureRenderTargetDescription &desc,
                                                     Flags flags)
    : QRhiTextureRenderTarget(rhi, desc, flags),
      d(new QMetalRenderTargetData)
{
}

QMetalTextureRenderTarget::~QMetalTextureRenderTarget()
{
    destroy();
    delete d;
}

void QMetalTextureRenderTarget::destroy()
{
    // nothing to do here
}

QRhiRenderPassDescriptor *QMetalTextureRenderTarget::newCompatibleRenderPassDescriptor()
{
    const int colorAttachmentCount = m_desc.cendColorAttachments() - m_desc.cbeginColorAttachments();
    QMetalRenderPassDescriptor *rpD = new QMetalRenderPassDescriptor(m_rhi);
    rpD->colorAttachmentCount = colorAttachmentCount;
    rpD->hasDepthStencil = m_desc.depthStencilBuffer() || m_desc.depthTexture();

    for (int i = 0; i < colorAttachmentCount; ++i) {
        const QRhiColorAttachment *colorAtt = m_desc.colorAttachmentAt(i);
        QMetalTexture *texD = QRHI_RES(QMetalTexture, colorAtt->texture());
        QMetalRenderBuffer *rbD = QRHI_RES(QMetalRenderBuffer, colorAtt->renderBuffer());
        rpD->colorFormat[i] = int(texD ? texD->d->format : rbD->d->format);
    }

    if (m_desc.depthTexture())
        rpD->dsFormat = int(QRHI_RES(QMetalTexture, m_desc.depthTexture())->d->format);
    else if (m_desc.depthStencilBuffer())
        rpD->dsFormat = int(QRHI_RES(QMetalRenderBuffer, m_desc.depthStencilBuffer())->d->format);

    rpD->updateSerializedFormat();
    return rpD;
}

bool QMetalTextureRenderTarget::create()
{
    QRHI_RES_RHI(QRhiMetal);
    const bool hasColorAttachments = m_desc.cbeginColorAttachments() != m_desc.cendColorAttachments();
    Q_ASSERT(hasColorAttachments || m_desc.depthTexture());
    Q_ASSERT(!m_desc.depthStencilBuffer() || !m_desc.depthTexture());
    const bool hasDepthStencil = m_desc.depthStencilBuffer() || m_desc.depthTexture();

    d->colorAttCount = 0;
    int attIndex = 0;
    for (auto it = m_desc.cbeginColorAttachments(), itEnd = m_desc.cendColorAttachments(); it != itEnd; ++it, ++attIndex) {
        d->colorAttCount += 1;
        QMetalTexture *texD = QRHI_RES(QMetalTexture, it->texture());
        QMetalRenderBuffer *rbD = QRHI_RES(QMetalRenderBuffer, it->renderBuffer());
        Q_ASSERT(texD || rbD);
        id<MTLTexture> dst = nil;
        bool is3D = false;
        if (texD) {
            dst = texD->d->tex;
            if (attIndex == 0) {
                d->pixelSize = rhiD->q->sizeForMipLevel(it->level(), texD->pixelSize());
                d->sampleCount = texD->samples;
            }
            is3D = texD->flags().testFlag(QRhiTexture::ThreeDimensional);
        } else if (rbD) {
            dst = rbD->d->tex;
            if (attIndex == 0) {
                d->pixelSize = rbD->pixelSize();
                d->sampleCount = rbD->samples;
            }
        }
        QMetalRenderTargetData::ColorAtt colorAtt;
        colorAtt.tex = dst;
        colorAtt.arrayLayer = is3D ? 0 : it->layer();
        colorAtt.slice = is3D ? it->layer() : 0;
        colorAtt.level = it->level();
        QMetalTexture *resTexD = QRHI_RES(QMetalTexture, it->resolveTexture());
        colorAtt.resolveTex = resTexD ? resTexD->d->tex : nil;
        colorAtt.resolveLayer = it->resolveLayer();
        colorAtt.resolveLevel = it->resolveLevel();
        d->fb.colorAtt[attIndex] = colorAtt;
    }
    d->dpr = 1;

    if (hasDepthStencil) {
        if (m_desc.depthTexture()) {
            QMetalTexture *depthTexD = QRHI_RES(QMetalTexture, m_desc.depthTexture());
            d->fb.dsTex = depthTexD->d->tex;
            d->fb.hasStencil = false;
            d->fb.depthNeedsStore = true;
            if (d->colorAttCount == 0) {
                d->pixelSize = depthTexD->pixelSize();
                d->sampleCount = depthTexD->samples;
            }
        } else {
            QMetalRenderBuffer *depthRbD = QRHI_RES(QMetalRenderBuffer, m_desc.depthStencilBuffer());
            d->fb.dsTex = depthRbD->d->tex;
            d->fb.hasStencil = true;
            d->fb.depthNeedsStore = false;
            if (d->colorAttCount == 0) {
                d->pixelSize = depthRbD->pixelSize();
                d->sampleCount = depthRbD->samples;
            }
        }
        d->dsAttCount = 1;
    } else {
        d->dsAttCount = 0;
    }

    QRhiRenderTargetAttachmentTracker::updateResIdList<QMetalTexture, QMetalRenderBuffer>(m_desc, &d->currentResIdList);

    return true;
}

QSize QMetalTextureRenderTarget::pixelSize() const
{
    if (!QRhiRenderTargetAttachmentTracker::isUpToDate<QMetalTexture, QMetalRenderBuffer>(m_desc, d->currentResIdList))
        const_cast<QMetalTextureRenderTarget *>(this)->create();

    return d->pixelSize;
}

float QMetalTextureRenderTarget::devicePixelRatio() const
{
    return d->dpr;
}

int QMetalTextureRenderTarget::sampleCount() const
{
    return d->sampleCount;
}

QMetalShaderResourceBindings::QMetalShaderResourceBindings(QRhiImplementation *rhi)
    : QRhiShaderResourceBindings(rhi)
{
}

QMetalShaderResourceBindings::~QMetalShaderResourceBindings()
{
    destroy();
}

void QMetalShaderResourceBindings::destroy()
{
    sortedBindings.clear();
    maxBinding = -1;
}

bool QMetalShaderResourceBindings::create()
{
    if (!sortedBindings.isEmpty())
        destroy();

    QRHI_RES_RHI(QRhiMetal);
    if (!rhiD->sanityCheckShaderResourceBindings(this))
        return false;

    rhiD->updateLayoutDesc(this);

    std::copy(m_bindings.cbegin(), m_bindings.cend(), std::back_inserter(sortedBindings));
    std::sort(sortedBindings.begin(), sortedBindings.end(),
              [](const QRhiShaderResourceBinding &a, const QRhiShaderResourceBinding &b)
    {
        return a.data()->binding < b.data()->binding;
    });
    if (!sortedBindings.isEmpty())
        maxBinding = sortedBindings.last().data()->binding;
    else
        maxBinding = -1;

    boundResourceData.resize(sortedBindings.count());

    for (BoundResourceData &bd : boundResourceData)
        memset(&bd, 0, sizeof(BoundResourceData));

    generation += 1;
    return true;
}

void QMetalShaderResourceBindings::updateResources(UpdateFlags flags)
{
    sortedBindings.clear();
    std::copy(m_bindings.cbegin(), m_bindings.cend(), std::back_inserter(sortedBindings));
    if (!flags.testFlag(BindingsAreSorted)) {
        std::sort(sortedBindings.begin(), sortedBindings.end(),
                  [](const QRhiShaderResourceBinding &a, const QRhiShaderResourceBinding &b)
        {
            return a.data()->binding < b.data()->binding;
        });
    }

    for (BoundResourceData &bd : boundResourceData)
        memset(&bd, 0, sizeof(BoundResourceData));

    generation += 1;
}

QMetalGraphicsPipeline::QMetalGraphicsPipeline(QRhiImplementation *rhi)
    : QRhiGraphicsPipeline(rhi),
      d(new QMetalGraphicsPipelineData)
{
    d->q = this;
    d->tess.q = d;
}

QMetalGraphicsPipeline::~QMetalGraphicsPipeline()
{
    destroy();
    delete d;
}

void QMetalGraphicsPipeline::destroy()
{
    d->vs.destroy();
    d->fs.destroy();

    d->tess.compVs[0].destroy();
    d->tess.compVs[1].destroy();
    d->tess.compVs[2].destroy();

    d->tess.compTesc.destroy();
    d->tess.vertTese.destroy();

    qDeleteAll(d->tess.deviceLocalWorkBuffers);
    d->tess.deviceLocalWorkBuffers.clear();
    qDeleteAll(d->tess.hostVisibleWorkBuffers);
    d->tess.hostVisibleWorkBuffers.clear();

    if (!d->ps && !d->ds
            && !d->tess.vertexComputeState[0] && !d->tess.vertexComputeState[1] && !d->tess.vertexComputeState[2]
            && !d->tess.tessControlComputeState)
    {
        return;
    }

    QRhiMetalData::DeferredReleaseEntry e;
    e.type = QRhiMetalData::DeferredReleaseEntry::GraphicsPipeline;
    e.lastActiveFrameSlot = lastActiveFrameSlot;
    e.graphicsPipeline.pipelineState = d->ps;
    e.graphicsPipeline.depthStencilState = d->ds;
    e.graphicsPipeline.tessVertexComputeState = d->tess.vertexComputeState;
    e.graphicsPipeline.tessTessControlComputeState = d->tess.tessControlComputeState;
    d->ps = nil;
    d->ds = nil;
    d->tess.vertexComputeState = {};
    d->tess.tessControlComputeState = nil;

    QRHI_RES_RHI(QRhiMetal);
    if (rhiD) {
        rhiD->d->releaseQueue.append(e);
        rhiD->unregisterResource(this);
    }
}

static inline MTLVertexFormat toMetalAttributeFormat(QRhiVertexInputAttribute::Format format)
{
    switch (format) {
    case QRhiVertexInputAttribute::Float4:
        return MTLVertexFormatFloat4;
    case QRhiVertexInputAttribute::Float3:
        return MTLVertexFormatFloat3;
    case QRhiVertexInputAttribute::Float2:
        return MTLVertexFormatFloat2;
    case QRhiVertexInputAttribute::Float:
        return MTLVertexFormatFloat;
    case QRhiVertexInputAttribute::UNormByte4:
        return MTLVertexFormatUChar4Normalized;
    case QRhiVertexInputAttribute::UNormByte2:
        return MTLVertexFormatUChar2Normalized;
    case QRhiVertexInputAttribute::UNormByte:
        return MTLVertexFormatUCharNormalized;
    case QRhiVertexInputAttribute::UInt4:
        return MTLVertexFormatUInt4;
    case QRhiVertexInputAttribute::UInt3:
        return MTLVertexFormatUInt3;
    case QRhiVertexInputAttribute::UInt2:
        return MTLVertexFormatUInt2;
    case QRhiVertexInputAttribute::UInt:
        return MTLVertexFormatUInt;
    case QRhiVertexInputAttribute::SInt4:
        return MTLVertexFormatInt4;
    case QRhiVertexInputAttribute::SInt3:
        return MTLVertexFormatInt3;
    case QRhiVertexInputAttribute::SInt2:
        return MTLVertexFormatInt2;
    case QRhiVertexInputAttribute::SInt:
        return MTLVertexFormatInt;
    default:
        Q_UNREACHABLE();
        return MTLVertexFormatFloat4;
    }
}

static inline MTLBlendFactor toMetalBlendFactor(QRhiGraphicsPipeline::BlendFactor f)
{
    switch (f) {
    case QRhiGraphicsPipeline::Zero:
        return MTLBlendFactorZero;
    case QRhiGraphicsPipeline::One:
        return MTLBlendFactorOne;
    case QRhiGraphicsPipeline::SrcColor:
        return MTLBlendFactorSourceColor;
    case QRhiGraphicsPipeline::OneMinusSrcColor:
        return MTLBlendFactorOneMinusSourceColor;
    case QRhiGraphicsPipeline::DstColor:
        return MTLBlendFactorDestinationColor;
    case QRhiGraphicsPipeline::OneMinusDstColor:
        return MTLBlendFactorOneMinusDestinationColor;
    case QRhiGraphicsPipeline::SrcAlpha:
        return MTLBlendFactorSourceAlpha;
    case QRhiGraphicsPipeline::OneMinusSrcAlpha:
        return MTLBlendFactorOneMinusSourceAlpha;
    case QRhiGraphicsPipeline::DstAlpha:
        return MTLBlendFactorDestinationAlpha;
    case QRhiGraphicsPipeline::OneMinusDstAlpha:
        return MTLBlendFactorOneMinusDestinationAlpha;
    case QRhiGraphicsPipeline::ConstantColor:
        return MTLBlendFactorBlendColor;
    case QRhiGraphicsPipeline::ConstantAlpha:
        return MTLBlendFactorBlendAlpha;
    case QRhiGraphicsPipeline::OneMinusConstantColor:
        return MTLBlendFactorOneMinusBlendColor;
    case QRhiGraphicsPipeline::OneMinusConstantAlpha:
        return MTLBlendFactorOneMinusBlendAlpha;
    case QRhiGraphicsPipeline::SrcAlphaSaturate:
        return MTLBlendFactorSourceAlphaSaturated;
    case QRhiGraphicsPipeline::Src1Color:
        return MTLBlendFactorSource1Color;
    case QRhiGraphicsPipeline::OneMinusSrc1Color:
        return MTLBlendFactorOneMinusSource1Color;
    case QRhiGraphicsPipeline::Src1Alpha:
        return MTLBlendFactorSource1Alpha;
    case QRhiGraphicsPipeline::OneMinusSrc1Alpha:
        return MTLBlendFactorOneMinusSource1Alpha;
    default:
        Q_UNREACHABLE();
        return MTLBlendFactorZero;
    }
}

static inline MTLBlendOperation toMetalBlendOp(QRhiGraphicsPipeline::BlendOp op)
{
    switch (op) {
    case QRhiGraphicsPipeline::Add:
        return MTLBlendOperationAdd;
    case QRhiGraphicsPipeline::Subtract:
        return MTLBlendOperationSubtract;
    case QRhiGraphicsPipeline::ReverseSubtract:
        return MTLBlendOperationReverseSubtract;
    case QRhiGraphicsPipeline::Min:
        return MTLBlendOperationMin;
    case QRhiGraphicsPipeline::Max:
        return MTLBlendOperationMax;
    default:
        Q_UNREACHABLE();
        return MTLBlendOperationAdd;
    }
}

static inline uint toMetalColorWriteMask(QRhiGraphicsPipeline::ColorMask c)
{
    uint f = 0;
    if (c.testFlag(QRhiGraphicsPipeline::R))
        f |= MTLColorWriteMaskRed;
    if (c.testFlag(QRhiGraphicsPipeline::G))
        f |= MTLColorWriteMaskGreen;
    if (c.testFlag(QRhiGraphicsPipeline::B))
        f |= MTLColorWriteMaskBlue;
    if (c.testFlag(QRhiGraphicsPipeline::A))
        f |= MTLColorWriteMaskAlpha;
    return f;
}

static inline MTLCompareFunction toMetalCompareOp(QRhiGraphicsPipeline::CompareOp op)
{
    switch (op) {
    case QRhiGraphicsPipeline::Never:
        return MTLCompareFunctionNever;
    case QRhiGraphicsPipeline::Less:
        return MTLCompareFunctionLess;
    case QRhiGraphicsPipeline::Equal:
        return MTLCompareFunctionEqual;
    case QRhiGraphicsPipeline::LessOrEqual:
        return MTLCompareFunctionLessEqual;
    case QRhiGraphicsPipeline::Greater:
        return MTLCompareFunctionGreater;
    case QRhiGraphicsPipeline::NotEqual:
        return MTLCompareFunctionNotEqual;
    case QRhiGraphicsPipeline::GreaterOrEqual:
        return MTLCompareFunctionGreaterEqual;
    case QRhiGraphicsPipeline::Always:
        return MTLCompareFunctionAlways;
    default:
        Q_UNREACHABLE();
        return MTLCompareFunctionAlways;
    }
}

static inline MTLStencilOperation toMetalStencilOp(QRhiGraphicsPipeline::StencilOp op)
{
    switch (op) {
    case QRhiGraphicsPipeline::StencilZero:
        return MTLStencilOperationZero;
    case QRhiGraphicsPipeline::Keep:
        return MTLStencilOperationKeep;
    case QRhiGraphicsPipeline::Replace:
        return MTLStencilOperationReplace;
    case QRhiGraphicsPipeline::IncrementAndClamp:
        return MTLStencilOperationIncrementClamp;
    case QRhiGraphicsPipeline::DecrementAndClamp:
        return MTLStencilOperationDecrementClamp;
    case QRhiGraphicsPipeline::Invert:
        return MTLStencilOperationInvert;
    case QRhiGraphicsPipeline::IncrementAndWrap:
        return MTLStencilOperationIncrementWrap;
    case QRhiGraphicsPipeline::DecrementAndWrap:
        return MTLStencilOperationDecrementWrap;
    default:
        Q_UNREACHABLE();
        return MTLStencilOperationKeep;
    }
}

static inline MTLPrimitiveType toMetalPrimitiveType(QRhiGraphicsPipeline::Topology t)
{
    switch (t) {
    case QRhiGraphicsPipeline::Triangles:
        return MTLPrimitiveTypeTriangle;
    case QRhiGraphicsPipeline::TriangleStrip:
        return MTLPrimitiveTypeTriangleStrip;
    case QRhiGraphicsPipeline::Lines:
        return MTLPrimitiveTypeLine;
    case QRhiGraphicsPipeline::LineStrip:
        return MTLPrimitiveTypeLineStrip;
    case QRhiGraphicsPipeline::Points:
        return MTLPrimitiveTypePoint;
    default:
        Q_UNREACHABLE();
        return MTLPrimitiveTypeTriangle;
    }
}

static inline MTLCullMode toMetalCullMode(QRhiGraphicsPipeline::CullMode c)
{
    switch (c) {
    case QRhiGraphicsPipeline::None:
        return MTLCullModeNone;
    case QRhiGraphicsPipeline::Front:
        return MTLCullModeFront;
    case QRhiGraphicsPipeline::Back:
        return MTLCullModeBack;
    default:
        Q_UNREACHABLE();
        return MTLCullModeNone;
    }
}

static inline MTLTriangleFillMode toMetalTriangleFillMode(QRhiGraphicsPipeline::PolygonMode mode)
{
    switch (mode) {
    case QRhiGraphicsPipeline::Fill:
        return MTLTriangleFillModeFill;
    case QRhiGraphicsPipeline::Line:
        return MTLTriangleFillModeLines;
    default:
        Q_UNREACHABLE();
        return MTLTriangleFillModeFill;
    }
}

static inline MTLWinding toMetalTessellationWindingOrder(QShaderDescription::TessellationWindingOrder w)
{
    switch (w) {
    case QShaderDescription::CwTessellationWindingOrder:
        return MTLWindingClockwise;
    case QShaderDescription::CcwTessellationWindingOrder:
        return MTLWindingCounterClockwise;
    default:
        // this is reachable, consider a tess.eval. shader not declaring it, the value is then Unknown
        return MTLWindingCounterClockwise;
    }
}

static inline MTLTessellationPartitionMode toMetalTessellationPartitionMode(QShaderDescription::TessellationPartitioning p)
{
    switch (p) {
    case QShaderDescription::EqualTessellationPartitioning:
        return MTLTessellationPartitionModePow2;
    case QShaderDescription::FractionalEvenTessellationPartitioning:
        return MTLTessellationPartitionModeFractionalEven;
    case QShaderDescription::FractionalOddTessellationPartitioning:
        return MTLTessellationPartitionModeFractionalOdd;
    default:
        // this is reachable, consider a tess.eval. shader not declaring it, the value is then Unknown
        return MTLTessellationPartitionModePow2;
    }
}

id<MTLLibrary> QRhiMetalData::createMetalLib(const QShader &shader, QShader::Variant shaderVariant,
                                             QString *error, QByteArray *entryPoint, QShaderKey *activeKey)
{
    QShaderKey key = { QShader::MetalLibShader, 20, shaderVariant };
    QShaderCode mtllib = shader.shader(key);
    if (mtllib.shader().isEmpty()) {
        key.setSourceVersion(12);
        mtllib = shader.shader(key);
    }
    if (!mtllib.shader().isEmpty()) {
        dispatch_data_t data = dispatch_data_create(mtllib.shader().constData(),
                                                    size_t(mtllib.shader().size()),
                                                    dispatch_get_global_queue(0, 0),
                                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithData: data error: &err];
        dispatch_release(data);
        if (!err) {
            *entryPoint = mtllib.entryPoint();
            *activeKey = key;
            return lib;
        } else {
            const QString msg = QString::fromNSString(err.localizedDescription);
            qWarning("Failed to load metallib from baked shader: %s", qPrintable(msg));
        }
    }

    key = { QShader::MslShader, 20, shaderVariant };
    QShaderCode mslSource = shader.shader(key);
    if (mslSource.shader().isEmpty()) {
        key.setSourceVersion(12);
        mslSource = shader.shader(key);
    }
    if (mslSource.shader().isEmpty()) {
        qWarning() << "No MSL 2.0 or 1.2 code found in baked shader" << shader;
        return nil;
    }

    NSString *src = [NSString stringWithUTF8String: mslSource.shader().constData()];
    MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = key.sourceVersion() == 20 ? MTLLanguageVersion2_0 : MTLLanguageVersion1_2;
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource: src options: opts error: &err];
    [opts release];
    // src is autoreleased

    // if lib is null and err is non-null, we had errors (fail)
    // if lib is non-null and err is non-null, we had warnings (success)
    // if lib is non-null and err is null, there were no errors or warnings (success)
    if (!lib) {
        const QString msg = QString::fromNSString(err.localizedDescription);
        *error = msg;
        return nil;
    }

    *entryPoint = mslSource.entryPoint();
    *activeKey = key;
    return lib;
}

id<MTLFunction> QRhiMetalData::createMSLShaderFunction(id<MTLLibrary> lib, const QByteArray &entryPoint)
{
    NSString *name = [NSString stringWithUTF8String: entryPoint.constData()];
    id<MTLFunction> f = [lib newFunctionWithName: name];
    [name release];
    return f;
}

void QMetalGraphicsPipeline::setupAttachmentsInMetalRenderPassDescriptor(void *metalRpDesc, QMetalRenderPassDescriptor *rpD)
{
    MTLRenderPipelineDescriptor *rpDesc = reinterpret_cast<MTLRenderPipelineDescriptor *>(metalRpDesc);

    if (rpD->colorAttachmentCount) {
        // defaults when no targetBlends are provided
        rpDesc.colorAttachments[0].pixelFormat = MTLPixelFormat(rpD->colorFormat[0]);
        rpDesc.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
        rpDesc.colorAttachments[0].blendingEnabled = false;

        Q_ASSERT(m_targetBlends.count() == rpD->colorAttachmentCount
                 || (m_targetBlends.isEmpty() && rpD->colorAttachmentCount == 1));

        for (uint i = 0, ie = uint(m_targetBlends.count()); i != ie; ++i) {
            const QRhiGraphicsPipeline::TargetBlend &b(m_targetBlends[int(i)]);
            rpDesc.colorAttachments[i].pixelFormat = MTLPixelFormat(rpD->colorFormat[i]);
            rpDesc.colorAttachments[i].blendingEnabled = b.enable;
            rpDesc.colorAttachments[i].sourceRGBBlendFactor = toMetalBlendFactor(b.srcColor);
            rpDesc.colorAttachments[i].destinationRGBBlendFactor = toMetalBlendFactor(b.dstColor);
            rpDesc.colorAttachments[i].rgbBlendOperation = toMetalBlendOp(b.opColor);
            rpDesc.colorAttachments[i].sourceAlphaBlendFactor = toMetalBlendFactor(b.srcAlpha);
            rpDesc.colorAttachments[i].destinationAlphaBlendFactor = toMetalBlendFactor(b.dstAlpha);
            rpDesc.colorAttachments[i].alphaBlendOperation = toMetalBlendOp(b.opAlpha);
            rpDesc.colorAttachments[i].writeMask = toMetalColorWriteMask(b.colorWrite);
        }
    }

    if (rpD->hasDepthStencil) {
        // Must only be set when a depth-stencil buffer will actually be bound,
        // validation blows up otherwise.
        MTLPixelFormat fmt = MTLPixelFormat(rpD->dsFormat);
        rpDesc.depthAttachmentPixelFormat = fmt;
#if defined(Q_OS_MACOS)
        if (fmt != MTLPixelFormatDepth16Unorm && fmt != MTLPixelFormatDepth32Float)
#else
        if (fmt != MTLPixelFormatDepth32Float)
#endif
            rpDesc.stencilAttachmentPixelFormat = fmt;
    }

    QRHI_RES_RHI(QRhiMetal);
    rpDesc.sampleCount = NSUInteger(rhiD->effectiveSampleCount(m_sampleCount));
}

void QMetalGraphicsPipeline::setupMetalDepthStencilDescriptor(void *metalDsDesc)
{
    MTLDepthStencilDescriptor *dsDesc = reinterpret_cast<MTLDepthStencilDescriptor *>(metalDsDesc);

    dsDesc.depthCompareFunction = m_depthTest ? toMetalCompareOp(m_depthOp) : MTLCompareFunctionAlways;
    dsDesc.depthWriteEnabled = m_depthWrite;
    if (m_stencilTest) {
        dsDesc.frontFaceStencil = [[MTLStencilDescriptor alloc] init];
        dsDesc.frontFaceStencil.stencilFailureOperation = toMetalStencilOp(m_stencilFront.failOp);
        dsDesc.frontFaceStencil.depthFailureOperation = toMetalStencilOp(m_stencilFront.depthFailOp);
        dsDesc.frontFaceStencil.depthStencilPassOperation = toMetalStencilOp(m_stencilFront.passOp);
        dsDesc.frontFaceStencil.stencilCompareFunction = toMetalCompareOp(m_stencilFront.compareOp);
        dsDesc.frontFaceStencil.readMask = m_stencilReadMask;
        dsDesc.frontFaceStencil.writeMask = m_stencilWriteMask;

        dsDesc.backFaceStencil = [[MTLStencilDescriptor alloc] init];
        dsDesc.backFaceStencil.stencilFailureOperation = toMetalStencilOp(m_stencilBack.failOp);
        dsDesc.backFaceStencil.depthFailureOperation = toMetalStencilOp(m_stencilBack.depthFailOp);
        dsDesc.backFaceStencil.depthStencilPassOperation = toMetalStencilOp(m_stencilBack.passOp);
        dsDesc.backFaceStencil.stencilCompareFunction = toMetalCompareOp(m_stencilBack.compareOp);
        dsDesc.backFaceStencil.readMask = m_stencilReadMask;
        dsDesc.backFaceStencil.writeMask = m_stencilWriteMask;
    }
}

void QMetalGraphicsPipeline::mapStates()
{
    d->winding = m_frontFace == CCW ? MTLWindingCounterClockwise : MTLWindingClockwise;
    d->cullMode = toMetalCullMode(m_cullMode);
    d->triangleFillMode = toMetalTriangleFillMode(m_polygonMode);
    d->depthBias = float(m_depthBias);
    d->slopeScaledDepthBias = m_slopeScaledDepthBias;
}

template<typename T>
void QMetalGraphicsPipelineData::setupVertexOrStageInputDescriptor(T *desc)
{
    // same binding space for vertex and constant buffers - work it around
    const int firstVertexBinding = QRHI_RES(QMetalShaderResourceBindings, q->shaderResourceBindings())->maxBinding + 1;

    QRhiVertexInputLayout vertexInputLayout = q->vertexInputLayout();
    for (auto it = vertexInputLayout.cbeginAttributes(), itEnd = vertexInputLayout.cendAttributes();
         it != itEnd; ++it)
    {
        const uint loc = uint(it->location());
        // either MTLVertexFormat or MTLAttributeFormat, the values are the same
        desc.attributes[loc].format = decltype(desc.attributes[loc].format)(toMetalAttributeFormat(it->format()));
        desc.attributes[loc].offset = NSUInteger(it->offset());
        desc.attributes[loc].bufferIndex = NSUInteger(firstVertexBinding + it->binding());
    }
    int bindingIndex = 0;
    for (auto it = vertexInputLayout.cbeginBindings(), itEnd = vertexInputLayout.cendBindings();
         it != itEnd; ++it, ++bindingIndex)
    {
        const uint layoutIdx = uint(firstVertexBinding + bindingIndex);
        using StepT = decltype(desc.layouts[layoutIdx].stepFunction);
        if (std::is_same_v<StepT, MTLStepFunction>) {
            desc.layouts[layoutIdx].stepFunction = StepT(
                    it->classification() == QRhiVertexInputBinding::PerInstance
                    ? MTLStepFunctionThreadPositionInGridY : MTLStepFunctionThreadPositionInGridX);
        } else {
            desc.layouts[layoutIdx].stepFunction = StepT(
                    it->classification() == QRhiVertexInputBinding::PerInstance
                    ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex);
        }
        desc.layouts[layoutIdx].stepRate = NSUInteger(it->instanceStepRate());
        desc.layouts[layoutIdx].stride = it->stride();
    }
}

void QRhiMetalData::trySeedingRenderPipelineFromBinaryArchive(MTLRenderPipelineDescriptor *rpDesc)
{
    if (@available(macOS 11.0, iOS 14.0, *)) {
        if (binArch)  {
            NSArray *binArchArray = [NSArray arrayWithObjects: binArch, nil];
            rpDesc.binaryArchives = binArchArray;
        }
    }
}

static bool canAddToBinaryArchive(QRhiMetalData *d)
{
    if (@available(macOS 11.0, iOS 14.0, *)) {
        if (!d->binArch)
            return false;

        // ### QTBUG-106703, QTBUG-108216, revisit after 13.0
        if (!d->binArchWasEmpty && d->q->osMajor >= 13) {
            static bool logPrinted = false;
            if (!logPrinted) {
                logPrinted = true;
                qCDebug(QRHI_LOG_INFO, "Skipping adding more pipelines to MTLBinaryArchive on this OS version (%d.%d) due to known issues.",
                        d->q->osMajor, d->q->osMinor);
            }
            return false;
        }

        return true;
    } else {
        return false;
    }
}

void QRhiMetalData::addRenderPipelineToBinaryArchive(MTLRenderPipelineDescriptor *rpDesc)
{
    if (@available(macOS 11.0, iOS 14.0, *)) {
        if (canAddToBinaryArchive(this)) {
            NSError *err = nil;
            if (![binArch addRenderPipelineFunctionsWithDescriptor: rpDesc error: &err]) {
                const QString msg = QString::fromNSString(err.localizedDescription);
                qWarning("Failed to collect render pipeline functions to binary archive: %s", qPrintable(msg));
            }
        }
    }
}

bool QMetalGraphicsPipeline::createVertexFragmentPipeline()
{
    QRHI_RES_RHI(QRhiMetal);

    MTLVertexDescriptor *vertexDesc = [MTLVertexDescriptor vertexDescriptor];
    d->setupVertexOrStageInputDescriptor(vertexDesc);

    MTLRenderPipelineDescriptor *rpDesc = [[MTLRenderPipelineDescriptor alloc] init];
    rpDesc.vertexDescriptor = vertexDesc;

    // Mutability cannot be determined (slotted buffers could be set as
    // MTLMutabilityImmutable, but then we potentially need a different
    // descriptor for each buffer combination as this depends on the actual
    // buffers not just the resource binding layout), so leave
    // rpDesc.vertex/fragmentBuffers at the defaults.

    for (const QRhiShaderStage &shaderStage : std::as_const(m_shaderStages)) {
        auto cacheIt = rhiD->d->shaderCache.constFind(shaderStage);
        if (cacheIt != rhiD->d->shaderCache.constEnd()) {
            switch (shaderStage.type()) {
            case QRhiShaderStage::Vertex:
                d->vs = *cacheIt;
                [d->vs.lib retain];
                [d->vs.func retain];
                rpDesc.vertexFunction = d->vs.func;
                break;
            case QRhiShaderStage::Fragment:
                d->fs = *cacheIt;
                [d->fs.lib retain];
                [d->fs.func retain];
                rpDesc.fragmentFunction = d->fs.func;
                break;
            default:
                break;
            }
        } else {
            const QShader shader = shaderStage.shader();
            QString error;
            QByteArray entryPoint;
            QShaderKey activeKey;
            id<MTLLibrary> lib = rhiD->d->createMetalLib(shader, shaderStage.shaderVariant(),
                                                         &error, &entryPoint, &activeKey);
            if (!lib) {
                qWarning("MSL shader compilation failed: %s", qPrintable(error));
                return false;
            }
            id<MTLFunction> func = rhiD->d->createMSLShaderFunction(lib, entryPoint);
            if (!func) {
                qWarning("MSL function for entry point %s not found", entryPoint.constData());
                [lib release];
                return false;
            }
            if (rhiD->d->shaderCache.count() >= QRhiMetal::MAX_SHADER_CACHE_ENTRIES) {
                // Use the simplest strategy: too many cached shaders -> drop them all.
                for (QMetalShader &s : rhiD->d->shaderCache)
                    s.destroy();
                rhiD->d->shaderCache.clear();
            }
            switch (shaderStage.type()) {
            case QRhiShaderStage::Vertex:
                d->vs.lib = lib;
                d->vs.func = func;
                d->vs.nativeResourceBindingMap = shader.nativeResourceBindingMap(activeKey);
                rhiD->d->shaderCache.insert(shaderStage, d->vs);
                [d->vs.lib retain];
                [d->vs.func retain];
                rpDesc.vertexFunction = func;
                break;
            case QRhiShaderStage::Fragment:
                d->fs.lib = lib;
                d->fs.func = func;
                d->fs.nativeResourceBindingMap = shader.nativeResourceBindingMap(activeKey);
                rhiD->d->shaderCache.insert(shaderStage, d->fs);
                [d->fs.lib retain];
                [d->fs.func retain];
                rpDesc.fragmentFunction = func;
                break;
            default:
                [func release];
                [lib release];
                break;
            }
        }
    }

    QMetalRenderPassDescriptor *rpD = QRHI_RES(QMetalRenderPassDescriptor, m_renderPassDesc);
    setupAttachmentsInMetalRenderPassDescriptor(rpDesc, rpD);

    rhiD->d->trySeedingRenderPipelineFromBinaryArchive(rpDesc);

    if (rhiD->rhiFlags.testFlag(QRhi::EnablePipelineCacheDataSave))
        rhiD->d->addRenderPipelineToBinaryArchive(rpDesc);

    NSError *err = nil;
    d->ps = [rhiD->d->dev newRenderPipelineStateWithDescriptor: rpDesc error: &err];
    [rpDesc release];
    if (!d->ps) {
        const QString msg = QString::fromNSString(err.localizedDescription);
        qWarning("Failed to create render pipeline state: %s", qPrintable(msg));
        return false;
    }

    MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
    setupMetalDepthStencilDescriptor(dsDesc);
    d->ds = [rhiD->d->dev newDepthStencilStateWithDescriptor: dsDesc];
    [dsDesc release];

    d->primitiveType = toMetalPrimitiveType(m_topology);
    mapStates();

    return true;
}

int QMetalGraphicsPipelineData::Tessellation::vsCompVariantToIndex(QShader::Variant vertexCompVariant)
{
    switch (vertexCompVariant) {
    case QShader::NonIndexedVertexAsComputeShader:
        return 0;
    case QShader::UInt32IndexedVertexAsComputeShader:
        return 1;
    case QShader::UInt16IndexedVertexAsComputeShader:
        return 2;
    default:
        break;
    }
    return -1;
}

id<MTLComputePipelineState> QMetalGraphicsPipelineData::Tessellation::vsCompPipeline(QRhiMetal *rhiD, QShader::Variant vertexCompVariant)
{
    const int varIndex = vsCompVariantToIndex(vertexCompVariant);
    if (varIndex >= 0 && vertexComputeState[varIndex])
        return vertexComputeState[varIndex];

    id<MTLFunction> func = nil;
    if (varIndex >= 0)
        func = compVs[varIndex].func;

    if (!func) {
        qWarning("No compute function found for vertex shader translated for tessellation, this should not happen");
        return nil;
    }

    const QMap<int, int> &ebb(compVs[varIndex].nativeShaderInfo.extraBufferBindings);
    const int indexBufferBinding = ebb.value(QShaderPrivate::MslTessVertIndicesBufferBinding, -1);

    MTLComputePipelineDescriptor *cpDesc = [MTLComputePipelineDescriptor new];
    cpDesc.computeFunction = func;
    cpDesc.threadGroupSizeIsMultipleOfThreadExecutionWidth = YES;
    cpDesc.stageInputDescriptor = [MTLStageInputOutputDescriptor stageInputOutputDescriptor];
    if (indexBufferBinding >= 0) {
        if (vertexCompVariant == QShader::UInt32IndexedVertexAsComputeShader) {
            cpDesc.stageInputDescriptor.indexType = MTLIndexTypeUInt32;
            cpDesc.stageInputDescriptor.indexBufferIndex = indexBufferBinding;
        } else if (vertexCompVariant == QShader::UInt16IndexedVertexAsComputeShader) {
            cpDesc.stageInputDescriptor.indexType = MTLIndexTypeUInt16;
            cpDesc.stageInputDescriptor.indexBufferIndex = indexBufferBinding;
        }
    }
    q->setupVertexOrStageInputDescriptor(cpDesc.stageInputDescriptor);

    rhiD->d->trySeedingComputePipelineFromBinaryArchive(cpDesc);

    if (rhiD->rhiFlags.testFlag(QRhi::EnablePipelineCacheDataSave))
        rhiD->d->addComputePipelineToBinaryArchive(cpDesc);

    NSError *err = nil;
    id<MTLComputePipelineState> ps = [rhiD->d->dev newComputePipelineStateWithDescriptor: cpDesc
            options: MTLPipelineOptionNone
            reflection: nil
            error: &err];
    [cpDesc release];
    if (!ps) {
        const QString msg = QString::fromNSString(err.localizedDescription);
        qWarning("Failed to create compute pipeline state: %s", qPrintable(msg));
    } else {
        vertexComputeState[varIndex] = ps;
    }
    // not retained, the only owner is vertexComputeState and so the QRhiGraphicsPipeline
    return ps;
}

id<MTLComputePipelineState> QMetalGraphicsPipelineData::Tessellation::tescCompPipeline(QRhiMetal *rhiD)
{
    if (tessControlComputeState)
        return tessControlComputeState;

    MTLComputePipelineDescriptor *cpDesc = [MTLComputePipelineDescriptor new];
    cpDesc.computeFunction = compTesc.func;

    rhiD->d->trySeedingComputePipelineFromBinaryArchive(cpDesc);

    if (rhiD->rhiFlags.testFlag(QRhi::EnablePipelineCacheDataSave))
        rhiD->d->addComputePipelineToBinaryArchive(cpDesc);

    NSError *err = nil;
    id<MTLComputePipelineState> ps = [rhiD->d->dev newComputePipelineStateWithDescriptor: cpDesc
            options: MTLPipelineOptionNone
            reflection: nil
            error: &err];
    [cpDesc release];
    if (!ps) {
        const QString msg = QString::fromNSString(err.localizedDescription);
        qWarning("Failed to create compute pipeline state: %s", qPrintable(msg));
    } else {
        tessControlComputeState = ps;
    }
    // not retained, the only owner is tessControlComputeState and so the QRhiGraphicsPipeline
    return ps;
}

static inline bool hasBuiltin(const QVector<QShaderDescription::BuiltinVariable> &builtinList, QShaderDescription::BuiltinType builtin)
{
    return std::find_if(builtinList.cbegin(), builtinList.cend(),
                        [builtin](const QShaderDescription::BuiltinVariable &b) { return b.type == builtin; }) != builtinList.cend();
}

id<MTLRenderPipelineState> QMetalGraphicsPipelineData::Tessellation::teseFragRenderPipeline(QRhiMetal *rhiD, QMetalGraphicsPipeline *pipeline)
{
    if (pipeline->d->ps)
        return pipeline->d->ps;

    MTLRenderPipelineDescriptor *rpDesc = [[MTLRenderPipelineDescriptor alloc] init];
    MTLVertexDescriptor *vertexDesc = [MTLVertexDescriptor vertexDescriptor];

    // Going to use the same buffer indices for the extra buffers as the tess.control compute shader did.
    const QMap<int, int> &ebb(compTesc.nativeShaderInfo.extraBufferBindings);
    const int tescOutputBufferBinding = ebb.value(QShaderPrivate::MslTessVertTescOutputBufferBinding, -1);
    const int tescPatchOutputBufferBinding = ebb.value(QShaderPrivate::MslTessTescPatchOutputBufferBinding, -1);
    const int tessFactorBufferBinding = ebb.value(QShaderPrivate::MslTessTescTessLevelBufferBinding, -1);

    QVarLengthArray<int, 16> teseInputLocations;
    for (const QShaderDescription::InOutVariable &v : vertTese.desc.inputVariables())
        teseInputLocations.append(v.location);

    quint32 offsetInTescOutput = 0;
    quint32 offsetInTescPatchOutput = 0;
    int lastLocation = -1;

    for (const QShaderDescription::InOutVariable &tescOutVar : compTesc.desc.outputVariables()) {
        const int location = tescOutVar.location;
        lastLocation = location;
        const QRhiVertexInputAttribute::Format format = rhiD->shaderDescVariableFormatToVertexInputFormat(tescOutVar.type);
        if (teseInputLocations.contains(location)) {
            if (tescOutVar.perPatch) {
                if (tescPatchOutputBufferBinding >= 0) {
                    vertexDesc.attributes[location].bufferIndex = tescPatchOutputBufferBinding;
                    vertexDesc.attributes[location].format = toMetalAttributeFormat(format);
                    vertexDesc.attributes[location].offset = offsetInTescPatchOutput;
                }
            } else {
                if (tescOutputBufferBinding >= 0) {
                    vertexDesc.attributes[location].bufferIndex = tescOutputBufferBinding;
                    vertexDesc.attributes[location].format = toMetalAttributeFormat(format);
                    vertexDesc.attributes[location].offset = offsetInTescOutput;
                }
            }
        }
        if (tescOutVar.perPatch)
            offsetInTescPatchOutput += rhiD->byteSizePerVertexForVertexInputFormat(format);
        else
            offsetInTescOutput += rhiD->byteSizePerVertexForVertexInputFormat(format);
    }

    const QVector<QShaderDescription::BuiltinVariable> tescOutBuiltins = compTesc.desc.outputBuiltinVariables();
    const QVector<QShaderDescription::BuiltinVariable> teseInBuiltins = vertTese.desc.inputBuiltinVariables();

    // Take a tess.control shader with an output variable layout(location = 0) out vec3 outColor[].
    // Assume it also writes to glPosition, e.g. gl_out[gl_InvocationID].gl_Position = ...
    // The tess.eval. shader translated to a Metal vertex function will then contain:
    //
    //    struct main0_in {
    //      float3 inColor [[attribute(0)]];
    //      float4 gl_Position [[attribute(1)]]; }
    //
    // The vertex description has to be set up accordingly. The color is
    // simple because that will be in the input/output variable list with
    // location 0. The position is a builtin however. So for now just
    // assume that builtins such as that come after the other variables,
    // with increasing location values.

    if (hasBuiltin(tescOutBuiltins, QShaderDescription::PositionBuiltin)
            && hasBuiltin(teseInBuiltins, QShaderDescription::PositionBuiltin)
            && tescOutputBufferBinding >= 0)
    {
        const int location = ++lastLocation;
        vertexDesc.attributes[location].bufferIndex = tescOutputBufferBinding;
        vertexDesc.attributes[location].format = toMetalAttributeFormat(QRhiVertexInputAttribute::Float4);
        vertexDesc.attributes[location].offset = offsetInTescOutput;
        offsetInTescOutput += 4 * sizeof(float);
    }

    // Per-patch outputs from the tess.control stage. are mostly handled above.
    // Consider:
    //   layout(location = 1) patch in vec3 stuff;
    //   layout(location = 2) patch in float more_stuff;
    //
    // This maps to:
    //
    //    struct main0_patchIn {
    //      float3 stuff [[attribute(1)]];
    //      float more_stuff [[attribute(2)]];
    //      patch_control_point<main0_in> gl_in; };
    //
    // These are already in place (location 1 and 2, referencing the per-patch
    // output buffer of tesc) at this point. But now if the tess.eval.shader
    // reads gl_TessLevelInner and gl_TessLevelOuter, which are also per-patch,
    // that adds, if the mode is triangles:
    // (assuming gl_Position got location 3, sorted based on the builtin type
    // (Position < Outer < Inner))
    //
    //     float4 gl_TessLevel [[attribute(4)]];
    //
    // or  if the mode is quads:
    //
    //    float4 gl_TessLevelOuter [[attribute(4)]];
    //    float2 gl_TessLevelInner [[attribute(5)]];
    //
    // Like gl_Position, these built-ins needs to be handled specially.
    // Note that the data is in a dedicated buffer, not in the patch buffer.

    const bool hasTessLevelOuter = hasBuiltin(tescOutBuiltins, QShaderDescription::TessLevelOuterBuiltin)
            && hasBuiltin(teseInBuiltins, QShaderDescription::TessLevelOuterBuiltin);
    const bool hasTessLevelInner = hasBuiltin(tescOutBuiltins, QShaderDescription::TessLevelInnerBuiltin)
            && hasBuiltin(teseInBuiltins, QShaderDescription::TessLevelInnerBuiltin);
    if (vertTese.desc.tessellationMode() != QShaderDescription::TrianglesTessellationMode
            && vertTese.desc.tessellationMode() != QShaderDescription::QuadTessellationMode)
    {
        qWarning("Tessellation evaluation stage mode is neither 'triangles' nor 'quads', this should not happen");
    }
    const bool trianglesMode = vertTese.desc.tessellationMode() == QShaderDescription::TrianglesTessellationMode;
    if ((hasTessLevelOuter || hasTessLevelInner) && tessFactorBufferBinding >= 0) {
        int loc0 = -1;
        int loc1 = -1;
        if (trianglesMode) {
            loc0 = ++lastLocation; // float4 gl_TessLevel
        } else {
            loc0 = ++lastLocation; // float4 gl_TessLevelOuter
            loc1 = ++lastLocation; // float2 gl_TessLevelInner
        }
        if (loc0 >= 0) {
            vertexDesc.attributes[loc0].bufferIndex = tessFactorBufferBinding;
            vertexDesc.attributes[loc0].format = MTLVertexFormatHalf4;
            vertexDesc.attributes[loc0].offset = 0;
        }
        if (loc1 >= 0) {
            vertexDesc.attributes[loc1].bufferIndex = tessFactorBufferBinding;
            vertexDesc.attributes[loc1].format = MTLVertexFormatHalf2;
            vertexDesc.attributes[loc1].offset = 8;
        }
        vertexDesc.layouts[tessFactorBufferBinding].stepFunction = MTLVertexStepFunctionPerPatch;
        vertexDesc.layouts[tessFactorBufferBinding].stride = trianglesMode ? 8 : 12;
    }

    if (offsetInTescOutput > 0) {
        vertexDesc.layouts[tescOutputBufferBinding].stepFunction = MTLVertexStepFunctionPerPatchControlPoint;
        vertexDesc.layouts[tescOutputBufferBinding].stride = offsetInTescOutput;
    }

    if (offsetInTescPatchOutput > 0) {
        vertexDesc.layouts[tescPatchOutputBufferBinding].stepFunction = MTLVertexStepFunctionPerPatch;
        vertexDesc.layouts[tescPatchOutputBufferBinding].stride = offsetInTescPatchOutput;
    }

    rpDesc.vertexDescriptor = vertexDesc;
    rpDesc.vertexFunction = vertTese.func;
    rpDesc.fragmentFunction = pipeline->d->fs.func;

    // The portable, cross-API approach is to use CCW, the results are then
    // identical (assuming the applied clipSpaceCorrMatrix) for all the 3D
    // APIs. The tess.eval. GLSL shader is thus expected to specify ccw. If it
    // doesn't, things may not work as expected.
    rpDesc.tessellationOutputWindingOrder = toMetalTessellationWindingOrder(vertTese.desc.tessellationWindingOrder());

    rpDesc.tessellationPartitionMode = toMetalTessellationPartitionMode(vertTese.desc.tessellationPartitioning());

    QMetalRenderPassDescriptor *rpD = QRHI_RES(QMetalRenderPassDescriptor, pipeline->renderPassDescriptor());
    pipeline->setupAttachmentsInMetalRenderPassDescriptor(rpDesc, rpD);

    rhiD->d->trySeedingRenderPipelineFromBinaryArchive(rpDesc);

    if (rhiD->rhiFlags.testFlag(QRhi::EnablePipelineCacheDataSave))
        rhiD->d->addRenderPipelineToBinaryArchive(rpDesc);

    NSError *err = nil;
    id<MTLRenderPipelineState> ps = [rhiD->d->dev newRenderPipelineStateWithDescriptor: rpDesc error: &err];
    [rpDesc release];
    if (!ps) {
        const QString msg = QString::fromNSString(err.localizedDescription);
        qWarning("Failed to create render pipeline state for tessellation: %s", qPrintable(msg));
    } else {
        // ps is stored in the QMetalGraphicsPipelineData so the end result in this
        // regard is no different from what createVertexFragmentPipeline does
        pipeline->d->ps = ps;
    }
    return ps;
}

QMetalBuffer *QMetalGraphicsPipelineData::Tessellation::acquireWorkBuffer(QRhiMetal *rhiD, quint32 size, WorkBufType type)
{
    QVector<QMetalBuffer *> *workBuffers = type == WorkBufType::DeviceLocal ? &deviceLocalWorkBuffers : &hostVisibleWorkBuffers;

    // Check if something is reusable as-is.
    for (QMetalBuffer *workBuf : *workBuffers) {
        if (workBuf && workBuf->lastActiveFrameSlot == -1 && workBuf->size() >= size) {
            workBuf->lastActiveFrameSlot = rhiD->currentFrameSlot;
            return workBuf;
        }
    }

    // Once the pool is above a certain threshold, see if there is something
    // unused (but too small) and recreate that our size.
    if (workBuffers->count() > QMTL_FRAMES_IN_FLIGHT * 8) {
        for (QMetalBuffer *workBuf : *workBuffers) {
            if (workBuf && workBuf->lastActiveFrameSlot == -1) {
                workBuf->setSize(size);
                if (workBuf->create()) {
                    workBuf->lastActiveFrameSlot = rhiD->currentFrameSlot;
                    return workBuf;
                }
            }
        }
    }

    // Add a new buffer to the pool.
    QMetalBuffer *buf;
    if (type == WorkBufType::DeviceLocal) {
        // for GPU->GPU data (non-slotted, not necessarily host writable)
        buf = new QMetalBuffer(rhiD, QRhiBuffer::Static, QRhiBuffer::UsageFlags(QMetalBuffer::WorkBufPoolUsage), size);
    } else {
        // for CPU->GPU (non-slotted, host writable/coherent)
        buf = new QMetalBuffer(rhiD, QRhiBuffer::Dynamic, QRhiBuffer::UsageFlags(QMetalBuffer::WorkBufPoolUsage), size);
    }
    if (buf->create()) {
        buf->lastActiveFrameSlot = rhiD->currentFrameSlot;
        workBuffers->append(buf);
        return buf;
    }

    qWarning("Failed to acquire work buffer of size %u", size);
    return nullptr;
}

bool QMetalGraphicsPipeline::createTessellationPipelines(const QShader &tessVert, const QShader &tesc, const QShader &tese, const QShader &tessFrag)
{
    QRHI_RES_RHI(QRhiMetal);
    QString error;
    QByteArray entryPoint;
    QShaderKey activeKey;

    const QShaderDescription tescDesc = tesc.description();
    const QShaderDescription teseDesc = tese.description();
    d->tess.inControlPointCount = uint(m_patchControlPointCount);
    d->tess.outControlPointCount = tescDesc.tessellationOutputVertexCount();
    if (!d->tess.outControlPointCount)
        d->tess.outControlPointCount = teseDesc.tessellationOutputVertexCount();

    if (!d->tess.outControlPointCount) {
        qWarning("Failed to determine output vertex count from the tessellation control or evaluation shader, cannot tessellate");
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }

    // Now the vertex shader is a compute shader.
    // It should have three dedicated *VertexAsComputeShader variants.
    // What the requested variant was (Standard or Batchable) plays no role here.
    // (the Qt Quick scenegraph does not use tessellation with its materials)
    // Create all three versions.

    bool variantsPresent[3] = {};
    const QVector<QShaderKey> tessVertKeys = tessVert.availableShaders();
    for (const QShaderKey &k : tessVertKeys) {
        switch (k.sourceVariant()) {
        case QShader::NonIndexedVertexAsComputeShader:
            variantsPresent[0] = true;
            break;
        case QShader::UInt32IndexedVertexAsComputeShader:
            variantsPresent[1] = true;
            break;
        case QShader::UInt16IndexedVertexAsComputeShader:
            variantsPresent[2] = true;
            break;
        default:
            break;
        }
    }
    if (!(variantsPresent[0] && variantsPresent[1] && variantsPresent[2])) {
        qWarning("Vertex shader is not prepared for Metal tessellation. Cannot tessellate. "
                 "Perhaps the relevant variants (UInt32IndexedVertexAsComputeShader et al) were not generated? "
                 "Try passing --msltess to qsb.");
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }

    int varIndex = 0; // Will map NonIndexed as 0, UInt32 as 1, UInt16 as 2. Do not change this ordering.
    for (QShader::Variant variant : {
         QShader::NonIndexedVertexAsComputeShader,
         QShader::UInt32IndexedVertexAsComputeShader,
         QShader::UInt16IndexedVertexAsComputeShader })
    {
        id<MTLLibrary> lib = rhiD->d->createMetalLib(tessVert, variant, &error, &entryPoint, &activeKey);
        if (!lib) {
            qWarning("MSL shader compilation failed for vertex-as-compute shader %d: %s", int(variant), qPrintable(error));
            d->tess.enabled = false;
            d->tess.failed = true;
            return false;
        }
        id<MTLFunction> func = rhiD->d->createMSLShaderFunction(lib, entryPoint);
        if (!func) {
            qWarning("MSL function for entry point %s not found", entryPoint.constData());
            [lib release];
            d->tess.enabled = false;
            d->tess.failed = true;
            return false;
        }
        QMetalShader &compVs(d->tess.compVs[varIndex]);
        compVs.lib = lib;
        compVs.func = func;
        compVs.desc = tessVert.description();
        compVs.nativeResourceBindingMap = tessVert.nativeResourceBindingMap(activeKey);
        compVs.nativeShaderInfo = tessVert.nativeShaderInfo(activeKey);

        // pre-create all three MTLComputePipelineStates
        if (!d->tess.vsCompPipeline(rhiD, variant)) {
            qWarning("Failed to pre-generate compute pipeline for vertex compute shader (tessellation variant %d)", int(variant));
            d->tess.enabled = false;
            d->tess.failed = true;
            return false;
        }

        ++varIndex;
    }

    // Pipeline #2 is a compute that runs the tessellation control (compute) shader
    id<MTLLibrary> tessControlLib = rhiD->d->createMetalLib(tesc, QShader::StandardShader, &error, &entryPoint, &activeKey);
    if (!tessControlLib) {
        qWarning("MSL shader compilation failed for tessellation control compute shader: %s", qPrintable(error));
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }
    id<MTLFunction> tessControlFunc = rhiD->d->createMSLShaderFunction(tessControlLib, entryPoint);
    if (!tessControlFunc) {
        qWarning("MSL function for entry point %s not found", entryPoint.constData());
        [tessControlLib release];
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }
    d->tess.compTesc.lib = tessControlLib;
    d->tess.compTesc.func = tessControlFunc;
    d->tess.compTesc.desc = tesc.description();
    d->tess.compTesc.nativeResourceBindingMap = tesc.nativeResourceBindingMap(activeKey);
    d->tess.compTesc.nativeShaderInfo = tesc.nativeShaderInfo(activeKey);
    if (!d->tess.tescCompPipeline(rhiD)) {
        qWarning("Failed to pre-generate compute pipeline for tessellation control shader");
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }

    // Pipeline #3 is a render pipeline with the tessellation evaluation (vertex) + the fragment shader
    id<MTLLibrary> tessEvalLib = rhiD->d->createMetalLib(tese, QShader::StandardShader, &error, &entryPoint, &activeKey);
    if (!tessEvalLib) {
        qWarning("MSL shader compilation failed for tessellation evaluation vertex shader: %s", qPrintable(error));
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }
    id<MTLFunction> tessEvalFunc = rhiD->d->createMSLShaderFunction(tessEvalLib, entryPoint);
    if (!tessEvalFunc) {
        qWarning("MSL function for entry point %s not found", entryPoint.constData());
        [tessEvalLib release];
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }
    d->tess.vertTese.lib = tessEvalLib;
    d->tess.vertTese.func = tessEvalFunc;
    d->tess.vertTese.desc = tese.description();
    d->tess.vertTese.nativeResourceBindingMap = tese.nativeResourceBindingMap(activeKey);
    d->tess.vertTese.nativeShaderInfo = tese.nativeShaderInfo(activeKey);

    id<MTLLibrary> fragLib = rhiD->d->createMetalLib(tessFrag, QShader::StandardShader, &error, &entryPoint, &activeKey);
    if (!fragLib) {
        qWarning("MSL shader compilation failed for fragment shader: %s", qPrintable(error));
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }
    id<MTLFunction> fragFunc = rhiD->d->createMSLShaderFunction(fragLib, entryPoint);
    if (!fragFunc) {
        qWarning("MSL function for entry point %s not found", entryPoint.constData());
        [fragLib release];
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }
    d->fs.lib = fragLib;
    d->fs.func = fragFunc;
    d->fs.nativeResourceBindingMap = tese.nativeResourceBindingMap(activeKey);

    if (!d->tess.teseFragRenderPipeline(rhiD, this)) {
        qWarning("Failed to pre-generate render pipeline for tessellation evaluation + fragment shader");
        d->tess.enabled = false;
        d->tess.failed = true;
        return false;
    }

    MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
    setupMetalDepthStencilDescriptor(dsDesc);
    d->ds = [rhiD->d->dev newDepthStencilStateWithDescriptor: dsDesc];
    [dsDesc release];

    // no primitiveType
    mapStates();

    return true;
}

bool QMetalGraphicsPipeline::create()
{
    destroy(); // no early test, always invoke and leave it to destroy to decide what to clean up

    QRHI_RES_RHI(QRhiMetal);
    rhiD->pipelineCreationStart();
    if (!rhiD->sanityCheckGraphicsPipeline(this))
        return false;

    // See if tessellation is involved. Things will be very different, if so.
    QShader tessVert;
    QShader tesc;
    QShader tese;
    QShader tessFrag;
    for (const QRhiShaderStage &shaderStage : std::as_const(m_shaderStages)) {
        switch (shaderStage.type()) {
        case QRhiShaderStage::Vertex:
            tessVert = shaderStage.shader();
            break;
        case QRhiShaderStage::TessellationControl:
            tesc = shaderStage.shader();
            break;
        case QRhiShaderStage::TessellationEvaluation:
            tese = shaderStage.shader();
            break;
        case QRhiShaderStage::Fragment:
            tessFrag = shaderStage.shader();
            break;
        default:
            break;
        }
    }
    d->tess.enabled = tesc.isValid() && tese.isValid() && m_topology == Patches && m_patchControlPointCount > 0;
    d->tess.failed = false;

    bool ok = d->tess.enabled ? createTessellationPipelines(tessVert, tesc, tese, tessFrag) : createVertexFragmentPipeline();
    if (!ok)
        return false;

    rhiD->pipelineCreationEnd();
    lastActiveFrameSlot = -1;
    generation += 1;
    rhiD->registerResource(this);
    return true;
}

QMetalComputePipeline::QMetalComputePipeline(QRhiImplementation *rhi)
    : QRhiComputePipeline(rhi),
      d(new QMetalComputePipelineData)
{
}

QMetalComputePipeline::~QMetalComputePipeline()
{
    destroy();
    delete d;
}

void QMetalComputePipeline::destroy()
{
    d->cs.destroy();

    if (!d->ps)
        return;

    QRhiMetalData::DeferredReleaseEntry e;
    e.type = QRhiMetalData::DeferredReleaseEntry::ComputePipeline;
    e.lastActiveFrameSlot = lastActiveFrameSlot;
    e.computePipeline.pipelineState = d->ps;
    d->ps = nil;

    QRHI_RES_RHI(QRhiMetal);
    if (rhiD) {
        rhiD->d->releaseQueue.append(e);
        rhiD->unregisterResource(this);
    }
}

void QRhiMetalData::trySeedingComputePipelineFromBinaryArchive(MTLComputePipelineDescriptor *cpDesc)
{
    if (@available(macOS 11.0, iOS 14.0, *)) {
        if (binArch)  {
            NSArray *binArchArray = [NSArray arrayWithObjects: binArch, nil];
            cpDesc.binaryArchives = binArchArray;
        }
    }
}

void QRhiMetalData::addComputePipelineToBinaryArchive(MTLComputePipelineDescriptor *cpDesc)
{
    if (@available(macOS 11.0, iOS 14.0, *)) {
        if (canAddToBinaryArchive(this)) {
            NSError *err = nil;
            if (![binArch addComputePipelineFunctionsWithDescriptor: cpDesc error: &err]) {
                const QString msg = QString::fromNSString(err.localizedDescription);
                qWarning("Failed to collect compute pipeline functions to binary archive: %s", qPrintable(msg));
            }
        }
    }
}

bool QMetalComputePipeline::create()
{
    if (d->ps)
        destroy();

    QRHI_RES_RHI(QRhiMetal);
    rhiD->pipelineCreationStart();

    auto cacheIt = rhiD->d->shaderCache.constFind(m_shaderStage);
    if (cacheIt != rhiD->d->shaderCache.constEnd()) {
        d->cs = *cacheIt;
    } else {
        const QShader shader = m_shaderStage.shader();
        QString error;
        QByteArray entryPoint;
        QShaderKey activeKey;
        id<MTLLibrary> lib = rhiD->d->createMetalLib(shader, m_shaderStage.shaderVariant(),
                                                     &error, &entryPoint, &activeKey);
        if (!lib) {
            qWarning("MSL shader compilation failed: %s", qPrintable(error));
            return false;
        }
        id<MTLFunction> func = rhiD->d->createMSLShaderFunction(lib, entryPoint);
        if (!func) {
            qWarning("MSL function for entry point %s not found", entryPoint.constData());
            [lib release];
            return false;
        }
        d->cs.lib = lib;
        d->cs.func = func;
        d->cs.localSize = shader.description().computeShaderLocalSize();
        d->cs.nativeResourceBindingMap = shader.nativeResourceBindingMap(activeKey);

        if (rhiD->d->shaderCache.count() >= QRhiMetal::MAX_SHADER_CACHE_ENTRIES) {
            for (QMetalShader &s : rhiD->d->shaderCache)
                s.destroy();
            rhiD->d->shaderCache.clear();
        }
        rhiD->d->shaderCache.insert(m_shaderStage, d->cs);
    }

    [d->cs.lib retain];
    [d->cs.func retain];

    d->localSize = MTLSizeMake(d->cs.localSize[0], d->cs.localSize[1], d->cs.localSize[2]);

    MTLComputePipelineDescriptor *cpDesc = [MTLComputePipelineDescriptor new];
    cpDesc.computeFunction = d->cs.func;

    rhiD->d->trySeedingComputePipelineFromBinaryArchive(cpDesc);

    if (rhiD->rhiFlags.testFlag(QRhi::EnablePipelineCacheDataSave))
        rhiD->d->addComputePipelineToBinaryArchive(cpDesc);

    NSError *err = nil;
    d->ps = [rhiD->d->dev newComputePipelineStateWithDescriptor: cpDesc
            options: MTLPipelineOptionNone
            reflection: nil
            error: &err];
    [cpDesc release];
    if (!d->ps) {
        const QString msg = QString::fromNSString(err.localizedDescription);
        qWarning("Failed to create compute pipeline state: %s", qPrintable(msg));
        return false;
    }

    rhiD->pipelineCreationEnd();
    lastActiveFrameSlot = -1;
    generation += 1;
    rhiD->registerResource(this);
    return true;
}

QMetalCommandBuffer::QMetalCommandBuffer(QRhiImplementation *rhi)
    : QRhiCommandBuffer(rhi),
      d(new QMetalCommandBufferData)
{
    resetState();
}

QMetalCommandBuffer::~QMetalCommandBuffer()
{
    destroy();
    delete d;
}

void QMetalCommandBuffer::destroy()
{
    // nothing to do here, we do not own the MTL cb object
}

const QRhiNativeHandles *QMetalCommandBuffer::nativeHandles()
{
    nativeHandlesStruct.commandBuffer = (MTLCommandBuffer *) d->cb;
    nativeHandlesStruct.encoder = (MTLRenderCommandEncoder *) d->currentRenderPassEncoder;
    return &nativeHandlesStruct;
}

void QMetalCommandBuffer::resetState()
{
    d->currentRenderPassEncoder = nil;
    d->currentComputePassEncoder = nil;
    d->tessellationComputeEncoder = nil;
    d->currentPassRpDesc = nil;
    resetPerPassState();
}

void QMetalCommandBuffer::resetPerPassState()
{
    recordingPass = NoPass;
    currentTarget = nullptr;
    resetPerPassCachedState();
}

void QMetalCommandBuffer::resetPerPassCachedState()
{
    currentGraphicsPipeline = nullptr;
    currentComputePipeline = nullptr;
    currentPipelineGeneration = 0;
    currentGraphicsSrb = nullptr;
    currentComputeSrb = nullptr;
    currentSrbGeneration = 0;
    currentResSlot = -1;
    currentIndexBuffer = nullptr;
    currentIndexOffset = 0;
    currentIndexFormat = QRhiCommandBuffer::IndexUInt16;
    currentCullMode = -1;
    currentTriangleFillMode = -1;
    currentFrontFaceWinding = -1;
    currentDepthBiasValues = { 0.0f, 0.0f };

    d->currentShaderResourceBindingState = {};
    d->currentDepthStencilState = nil;
    d->currentFirstVertexBinding = -1;
    d->currentVertexInputsBuffers.clear();
    d->currentVertexInputOffsets.clear();
}

QMetalSwapChain::QMetalSwapChain(QRhiImplementation *rhi)
    : QRhiSwapChain(rhi),
      rtWrapper(rhi, this),
      cbWrapper(rhi),
      d(new QMetalSwapChainData)
{
    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
        d->sem[i] = nullptr;
        d->msaaTex[i] = nil;
    }
}

QMetalSwapChain::~QMetalSwapChain()
{
    destroy();
    delete d;
}

void QMetalSwapChain::destroy()
{
    if (!d->layer)
        return;

    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
        if (d->sem[i]) {
            // the semaphores cannot be released if they do not have the initial value
            dispatch_semaphore_wait(d->sem[i], DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(d->sem[i]);

            dispatch_release(d->sem[i]);
            d->sem[i] = nullptr;
        }
    }

    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
        [d->msaaTex[i] release];
        d->msaaTex[i] = nil;
    }

    d->layer = nullptr;

    [d->curDrawable release];
    d->curDrawable = nil;

    QRHI_RES_RHI(QRhiMetal);
    if (rhiD) {
        rhiD->swapchains.remove(this);
        rhiD->unregisterResource(this);
    }
}

QRhiCommandBuffer *QMetalSwapChain::currentFrameCommandBuffer()
{
    return &cbWrapper;
}

QRhiRenderTarget *QMetalSwapChain::currentFrameRenderTarget()
{
    return &rtWrapper;
}

static inline CAMetalLayer *layerForWindow(QWindow *window)
{
    Q_ASSERT(window);
#ifdef Q_OS_MACOS
    NSView *view = reinterpret_cast<NSView *>(window->winId());
#else
    UIView *view = reinterpret_cast<UIView *>(window->winId());
#endif
    Q_ASSERT(view);
    return static_cast<CAMetalLayer *>(view.layer);
}

QSize QMetalSwapChain::surfacePixelSize()
{
    Q_ASSERT(m_window);
    CAMetalLayer *layer = d->layer;
    if (!layer)
        layer = layerForWindow(m_window);

    int height = (int)layer.bounds.size.height;
    int width = (int)layer.bounds.size.width;
    width *= layer.contentsScale;
    height *= layer.contentsScale;
    return QSize(width, height);
}

bool QMetalSwapChain::isFormatSupported(Format f)
{
#ifdef Q_OS_MACOS
    return f == SDR || f == HDRExtendedSrgbLinear;
#endif
    return f == SDR;
}

QRhiRenderPassDescriptor *QMetalSwapChain::newCompatibleRenderPassDescriptor()
{
    chooseFormats(); // ensure colorFormat and similar are filled out

    QMetalRenderPassDescriptor *rpD = new QMetalRenderPassDescriptor(m_rhi);
    rpD->colorAttachmentCount = 1;
    rpD->hasDepthStencil = m_depthStencil != nullptr;

    rpD->colorFormat[0] = int(d->colorFormat);

#ifdef Q_OS_MACOS
    // m_depthStencil may not be built yet so cannot rely on computed fields in it
    QRHI_RES_RHI(QRhiMetal);
    rpD->dsFormat = rhiD->d->dev.depth24Stencil8PixelFormatSupported
            ? MTLPixelFormatDepth24Unorm_Stencil8 : MTLPixelFormatDepth32Float_Stencil8;
#else
    rpD->dsFormat = MTLPixelFormatDepth32Float_Stencil8;
#endif

    rpD->updateSerializedFormat();
    return rpD;
}

void QMetalSwapChain::chooseFormats()
{
    QRHI_RES_RHI(QRhiMetal);
    samples = rhiD->effectiveSampleCount(m_sampleCount);
    // pick a format that is allowed for CAMetalLayer.pixelFormat
    if (m_format == HDRExtendedSrgbLinear) {
        d->colorFormat = MTLPixelFormatRGBA16Float;
        d->rhiColorFormat = QRhiTexture::RGBA16F;
        return;
    }
    d->colorFormat = m_flags.testFlag(sRGB) ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
    d->rhiColorFormat = QRhiTexture::BGRA8;
}

bool QMetalSwapChain::createOrResize()
{
    Q_ASSERT(m_window);

    const bool needsRegistration = !window || window != m_window;

    if (window && window != m_window)
        destroy();
    // else no destroy(), this is intentional

    QRHI_RES_RHI(QRhiMetal);
    if (needsRegistration)
        rhiD->swapchains.insert(this);

    window = m_window;

    if (window->surfaceType() != QSurface::MetalSurface) {
        qWarning("QMetalSwapChain only supports MetalSurface windows");
        return false;
    }

    d->layer = layerForWindow(window);
    Q_ASSERT(d->layer);

    chooseFormats();
    if (d->colorFormat != d->layer.pixelFormat)
        d->layer.pixelFormat = d->colorFormat;
#ifdef Q_OS_MACOS
    // Can't enable this on iOS until wantsExtendedDynamicRangeContent is available
    if (m_format == HDRExtendedSrgbLinear) {
        d->layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        d->layer.wantsExtendedDynamicRangeContent = YES;
    }
#endif

    if (m_flags.testFlag(UsedAsTransferSource))
        d->layer.framebufferOnly = NO;

#ifdef Q_OS_MACOS
    if (m_flags.testFlag(NoVSync))
        d->layer.displaySyncEnabled = NO;
#endif

    if (m_flags.testFlag(SurfaceHasPreMulAlpha)) {
        d->layer.opaque = NO;
    } else if (m_flags.testFlag(SurfaceHasNonPreMulAlpha)) {
        // The CoreAnimation compositor is said to expect premultiplied alpha,
        // so this is then wrong when it comes to the blending operations but
        // there's nothing we can do. Fortunately Qt Quick always outputs
        // premultiplied alpha so it is not a problem there.
        d->layer.opaque = NO;
    } else {
        d->layer.opaque = YES;
    }

    // Now set the layer's drawableSize which will stay set to the same value
    // until the next createOrResize(), thus ensuring atomicity with regards to
    // the drawable size in frames.
    int width = (int)d->layer.bounds.size.width;
    int height = (int)d->layer.bounds.size.height;
    CGSize layerSize = CGSizeMake(width, height);
    layerSize.width *= d->layer.contentsScale;
    layerSize.height *= d->layer.contentsScale;
    d->layer.drawableSize = layerSize;

    m_currentPixelSize = QSizeF::fromCGSize(layerSize).toSize();
    pixelSize = m_currentPixelSize;

    [d->layer setDevice: rhiD->d->dev];

    [d->curDrawable release];
    d->curDrawable = nil;

    for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
        if (!d->sem[i])
            d->sem[i] = dispatch_semaphore_create(QMTL_FRAMES_IN_FLIGHT - 1);
    }

    currentFrameSlot = 0;
    frameCount = 0;

    ds = m_depthStencil ? QRHI_RES(QMetalRenderBuffer, m_depthStencil) : nullptr;
    if (m_depthStencil && m_depthStencil->sampleCount() != m_sampleCount) {
        qWarning("Depth-stencil buffer's sampleCount (%d) does not match color buffers' sample count (%d). Expect problems.",
                 m_depthStencil->sampleCount(), m_sampleCount);
    }
    if (m_depthStencil && m_depthStencil->pixelSize() != pixelSize) {
        if (m_depthStencil->flags().testFlag(QRhiRenderBuffer::UsedWithSwapChainOnly)) {
            m_depthStencil->setPixelSize(pixelSize);
            if (!m_depthStencil->create())
                qWarning("Failed to rebuild swapchain's associated depth-stencil buffer for size %dx%d",
                         pixelSize.width(), pixelSize.height());
        } else {
            qWarning("Depth-stencil buffer's size (%dx%d) does not match the layer size (%dx%d). Expect problems.",
                     m_depthStencil->pixelSize().width(), m_depthStencil->pixelSize().height(),
                     pixelSize.width(), pixelSize.height());
        }
    }

    rtWrapper.setRenderPassDescriptor(m_renderPassDesc); // for the public getter in QRhiRenderTarget
    rtWrapper.d->pixelSize = pixelSize;
    rtWrapper.d->dpr = float(window->devicePixelRatio());
    rtWrapper.d->sampleCount = samples;
    rtWrapper.d->colorAttCount = 1;
    rtWrapper.d->dsAttCount = ds ? 1 : 0;

    qCDebug(QRHI_LOG_INFO, "got CAMetalLayer, size %dx%d", pixelSize.width(), pixelSize.height());

    if (samples > 1) {
        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.textureType = MTLTextureType2DMultisample;
        desc.pixelFormat = d->colorFormat;
        desc.width = NSUInteger(pixelSize.width());
        desc.height = NSUInteger(pixelSize.height());
        desc.sampleCount = NSUInteger(samples);
        desc.resourceOptions = MTLResourceStorageModePrivate;
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget;
        for (int i = 0; i < QMTL_FRAMES_IN_FLIGHT; ++i) {
            [d->msaaTex[i] release];
            d->msaaTex[i] = [rhiD->d->dev newTextureWithDescriptor: desc];
        }
        [desc release];
    }

    if (needsRegistration)
        rhiD->registerResource(this);

    return true;
}

QRhiSwapChainHdrInfo QMetalSwapChain::hdrInfo()
{
    QRhiSwapChainHdrInfo info;
    info.limitsType = QRhiSwapChainHdrInfo::ColorComponentValue;
    if (m_format == SDR) {
        info.limits.colorComponentValue.maxColorComponentValue = 1;
        return info;
    }

#ifdef Q_OS_MACOS
    info.isHardCodedDefaults = false;
    NSView *view = reinterpret_cast<NSView *>(window->winId());
    info.limits.colorComponentValue.maxColorComponentValue = view.window.screen.maximumExtendedDynamicRangeColorComponentValue;
#else
    // ### Fixme: Maybe retrieve the brightness from the screen and if we're not at full brightness we might be able to do more.
    // For now, assume 2, in line with iPhone 12 specs that claim 625 nits max brightness and 1200 nits max HDR brightness.
    info.isHardCodedDefaults = true;
    info.limits.colorComponentValue.maxColorComponentValue = 2;
#endif
    return info;
}

QT_END_NAMESPACE
