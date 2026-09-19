/* One-off, non-overwriting Steam RemoteStorage import for a separate test slot.
 * Build for x86_64 to match the game's bundled genuine Steam API. */
#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s libsteam_api.dylib source-file remote-name\n",
                argv[0]);
        return 2;
    }
    struct stat st;
    if (stat(argv[2], &st) || st.st_size != 97336) {
        fprintf(stderr, "expected a 97336-byte LEGO Marvel save\n");
        return 1;
    }
    FILE *file = fopen(argv[2], "rb");
    if (!file) { perror("open save"); return 1; }
    unsigned char data[97336], verify[97336];
    bool valid = fread(data, 1, sizeof(data), file) == sizeof(data) &&
                 memcmp(data, "HMGR", 4) == 0;
    fclose(file);
    if (!valid) { fprintf(stderr, "invalid LEGO Marvel save header\n"); return 1; }

    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    bool (*steam_init)(void) = dlsym(library, "SteamAPI_Init");
    void (*steam_shutdown)(void) = dlsym(library, "SteamAPI_Shutdown");
    void *(*steam_storage)(void) = dlsym(library, "SteamRemoteStorage");
    void *(*steam_utils)(void) = dlsym(library, "SteamUtils");
    if (!steam_init || !steam_shutdown || !steam_storage || !steam_utils ||
        !steam_init()) {
        fprintf(stderr, "Steam API unavailable\n");
        return 1;
    }
    int result = 1;
    void *utils = steam_utils();
    void *storage = steam_storage();
    if (!utils || !storage) goto done;
    void **uv = *(void ***)utils;
    void **sv = *(void ***)storage;
    uint32_t app_id = ((uint32_t (*)(void *))uv[9])(utils);
    if (app_id != 249130) {
        fprintf(stderr, "wrong Steam app id: %u\n", app_id);
        goto done;
    }
    int32_t count = ((int32_t (*)(void *))sv[15])(storage);
    if (count < 0 || count > 10000) goto done;
    for (int32_t i = 0; i < count; ++i) {
        int32_t size = 0;
        const char *name = ((const char *(*)(void *, int32_t, int32_t *))sv[16])(
            storage, i, &size);
        if (name && strcmp(name, argv[3]) == 0) {
            fprintf(stderr, "refusing to overwrite existing Steam file: %s\n", name);
            goto done;
        }
    }
    if (!((bool (*)(void *, const char *, const void *, int32_t))sv[0])(
            storage, argv[3], data, (int32_t)sizeof(data))) {
        fprintf(stderr, "Steam FileWrite failed\n");
        goto done;
    }
    int32_t read = ((int32_t (*)(void *, const char *, void *, int32_t))sv[1])(
        storage, argv[3], verify, (int32_t)sizeof(verify));
    if (read != sizeof(verify) || memcmp(data, verify, sizeof(data))) {
        fprintf(stderr, "Steam readback differs (bytes=%d)\n", read);
        goto done;
    }
    printf("imported %s for app %u; readback verified (%d bytes)\n",
           argv[3], app_id, read);
    result = 0;
done:
    steam_shutdown();
    dlclose(library);
    return result;
}
