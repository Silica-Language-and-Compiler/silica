/*
   Copyright 2026 COPYRIGHT-HOLDER-PLACEHOLDER (to be decided before this is merged)

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

// Route R1 spike (transport_ble_plan.md stage 12): what ESP-IDF's code expects of a C library and of
// ESP-IDF itself, answered on the bare-metal runtime. Each is said on the console when it matters.

void silica_rt_puts(const char *s);

void abort(void)
{
    silica_rt_puts("spike: abort\n");
    for (;;) {
    }
}

void __assert_func(const char *file, int line, const char *func, const char *expr)
{
    (void)file;
    (void)line;
    silica_rt_puts("spike: assert failed in ");
    silica_rt_puts(func ? func : "?");
    silica_rt_puts(": ");
    silica_rt_puts(expr ? expr : "?");
    silica_rt_puts("\n");
    for (;;) {
    }
}

unsigned int esp_log_timestamp(void)
{
    return 0;
}
