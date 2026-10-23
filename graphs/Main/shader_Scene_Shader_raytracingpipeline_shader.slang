#include "scene_legacy_callbacks.slang"
// Edit this shader, then Save to publish it to the project.
// Scene interface types are supplied by the shader manifest.
float3 SceneShaderMain(SceneContext scene, RayLaunch launch, inout RayQueryContext queries)
{
    ScenePayload payload = (ScenePayload)0;
    TraceAndShade(scene, queries, ShaderMain(launch), payload);
    return payload.Radiance;
}
