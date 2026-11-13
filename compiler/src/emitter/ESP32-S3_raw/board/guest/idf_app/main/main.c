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

/* The ESP-IDF application of a Silica guest image: ESP-IDF has started the chip; the Silica program
   runs on Silica's two schedulers (components/silica_guest). */

#include "silica_guest.h"

void app_main(void) {
    silica_guest_run();
}
