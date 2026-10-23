#include "scene_legacy_callbacks.slang"
// Edit this shader, then Save to publish it to the project.
// Scene interface types are supplied by the shader manifest.
void SceneShaderMain(SceneContext scene, Ray ray, inout RayQueryContext queries, inout ScenePayload payload)
{
    payload.Radiance = ShaderMain(ray);
}
