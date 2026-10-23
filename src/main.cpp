// Minimal Ludus application template (v3).
#include <ludus/foundation/base/version.hpp>

#include <string_view>

int main()
{
    return ludus::foundation::version_string().empty() ? 1 : 0;
}
