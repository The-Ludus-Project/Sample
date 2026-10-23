#pragma once
// Compatibility inputs for the original authored callbacks.
struct RayHit
{
    Ray IncomingRay;
    float3 PositionWorld;
    float DistanceWorld;
    float3 NormalWorld;
    uint Primitive;
    float2 Barycentric;
    float4 Color;
};
#include "shader_Shader_raytracingpipeline_closest_hit.slang"
#include "shader_Shader_raytracingpipeline_miss.slang"
#include "shader_Shader_raytracingpipeline_shader.slang"
