#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wasm_export.h"

static const char *g_module_dir;

static uint8_t *
read_runtime_buffer(const char *path, uint32_t *size)
{
    FILE *file = fopen(path, "rb");
    long length;
    uint8_t *buffer;

    if (!file) {
        fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) < 0
        || fseek(file, 0, SEEK_SET) != 0 || (uint64_t)length > UINT32_MAX) {
        fprintf(stderr, "size(%s): %s\n", path, strerror(errno));
        fclose(file);
        return NULL;
    }

    buffer = wasm_runtime_malloc((uint32_t)length);
    if (!buffer) {
        fprintf(stderr, "runtime allocation failed for %s\n", path);
        fclose(file);
        return NULL;
    }
    if (length > 0 && fread(buffer, (size_t)length, 1, file) != 1) {
        fprintf(stderr, "read(%s): %s\n", path, strerror(errno));
        wasm_runtime_free(buffer);
        fclose(file);
        return NULL;
    }
    fclose(file);
    *size = (uint32_t)length;
    return buffer;
}

static bool
module_reader_callback(package_type_t module_type, const char *module_name,
                       uint8_t **buffer, uint32_t *size)
{
    char path[1024];

    if (module_type != Wasm_Module_Bytecode) {
        fprintf(stderr, "unexpected dependency package type: %d\n",
                (int)module_type);
        return false;
    }
    if (snprintf(path, sizeof(path), "%s/%s.wasm", g_module_dir, module_name)
        >= (int)sizeof(path)) {
        fprintf(stderr, "dependency path too long\n");
        return false;
    }

    *buffer = read_runtime_buffer(path, size);
    return *buffer != NULL;
}

static void
module_destroyer_callback(uint8_t *buffer, uint32_t size)
{
    (void)size;
    wasm_runtime_free(buffer);
}

int
main(int argc, char **argv)
{
    RuntimeInitArgs init_args = { 0 };
    char error_buf[256] = { 0 };
    char consumer_path[1024];
    uint8_t *consumer_buffer = NULL;
    uint32_t consumer_size = 0;
    wasm_module_t consumer_module = NULL;
    wasm_module_inst_t consumer_instance = NULL;
    wasm_function_inst_t trigger = NULL;
    wasm_exec_env_t exec_env = NULL;
    uint32_t cells[2] = { 0, 0 };
    bool call_ok = false;
    const char *exception = NULL;
    int exit_code = 2;

    if (argc != 2) {
        fprintf(stderr, "usage: %s MODULE_DIR\n", argv[0]);
        return 2;
    }
    g_module_dir = argv[1];

    init_args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&init_args)) {
        fprintf(stderr, "wasm_runtime_full_init failed\n");
        return 2;
    }
    wasm_runtime_set_module_reader(module_reader_callback,
                                   module_destroyer_callback);

    if (snprintf(consumer_path, sizeof(consumer_path), "%s/consumer.wasm",
                 g_module_dir)
        >= (int)sizeof(consumer_path)) {
        fprintf(stderr, "consumer path too long\n");
        goto cleanup;
    }
    consumer_buffer = read_runtime_buffer(consumer_path, &consumer_size);
    if (!consumer_buffer)
        goto cleanup;

    consumer_module = wasm_runtime_load(consumer_buffer, consumer_size,
                                        error_buf, sizeof(error_buf));
    if (!consumer_module) {
        fprintf(stderr, "load_failed=%s\n", error_buf);
        goto cleanup;
    }

    consumer_instance = wasm_runtime_instantiate(
        consumer_module, 64 * 1024, 0, error_buf, sizeof(error_buf));
    if (!consumer_instance) {
        fprintf(stderr, "instantiate_failed=%s\n", error_buf);
        goto cleanup;
    }

    trigger = wasm_runtime_lookup_function(consumer_instance, "trigger");
    if (!trigger) {
        fprintf(stderr, "lookup_failed=trigger\n");
        goto cleanup;
    }

    exec_env = wasm_runtime_create_exec_env(consumer_instance, 64 * 1024);
    if (!exec_env) {
        fprintf(stderr, "exec_env_failed=1\n");
        goto cleanup;
    }

    call_ok = wasm_runtime_call_wasm(exec_env, trigger, 0, cells);
    exception = wasm_runtime_get_exception(consumer_instance);

    printf("call_ok=%d\n", call_ok ? 1 : 0);
    printf("result_i32=%" PRIu32 "\n", cells[0]);
    printf("exception=%s\n", exception ? exception : "<none>");

    /* Both outcomes are evidence and should leave a complete log:
       - correct: call_ok=0 with indirect-call type mismatch
       - vulnerable: call_ok=1 and result_i32=1337 */
    exit_code = 0;

cleanup:
    if (exec_env)
        wasm_runtime_destroy_exec_env(exec_env);
    if (consumer_instance)
        wasm_runtime_deinstantiate(consumer_instance);
    if (consumer_module)
        wasm_runtime_unload(consumer_module);
    if (consumer_buffer)
        wasm_runtime_free(consumer_buffer);
    wasm_runtime_destroy();
    return exit_code;
}
