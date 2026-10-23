float4 PSMain(RasterVarying value)
{
    //value.Color.rgb *= float3(1, 0, 1);
    return value.Color;
}
