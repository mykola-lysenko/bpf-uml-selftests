/*
 * bpf_loader_demo.c - BPF Verifier GDB Demo Loader
 *
 * Uses a REGULAR FILE (not FIFO) for synchronization to avoid
 * blocking-open issues with UML's ptrace architecture.
 *
 * The loader polls for /tmp/uml_go using nanosleep() between checks.
 * This is GDB-friendly: UML keeps running and GDB can hit breakpoints.
 *
 * Build: gcc -static -g -O0 -o bpf_loader_demo bpf_loader_demo.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <time.h>
#include <linux/bpf.h>

static int bpf_syscall(enum bpf_cmd cmd, union bpf_attr *attr, unsigned int size)
{
    return (int)syscall(__NR_bpf, cmd, attr, size);
}

/* Simple BPF socket filter: return 0 (drop) */
static struct bpf_insn prog[] = {
    { .code = BPF_ALU64 | BPF_MOV | BPF_K, .dst_reg = BPF_REG_0, .imm = 0 },
    { .code = BPF_JMP | BPF_EXIT },
};

#define READY_FILE "/tmp/uml_ready"
#define GO_FILE    "/tmp/uml_go"

int main(void)
{
    char license[] = "GPL";
    char log_buf[4096];
    union bpf_attr attr;
    struct stat st;
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 200000000 }; /* 200ms */
    int fd;

    printf("[bpf_loader_demo] PID = %d\n", getpid());
    fflush(stdout);

    /* Print GDB setup instructions */
    printf("[bpf_loader_demo]\n");
    printf("[bpf_loader_demo] === GDB SETUP INSTRUCTIONS ===\n");
    printf("[bpf_loader_demo]\n");
    printf("[bpf_loader_demo] 1. Find the UML main PID on the HOST:\n");
    printf("[bpf_loader_demo]      ps aux | grep <uml-kernel> | grep -v grep\n");
    printf("[bpf_loader_demo]\n");
    printf("[bpf_loader_demo] 2. Attach GDB to the UML main process:\n");
    printf("[bpf_loader_demo]      gdb <path-to-linux-uml-debug>\n");
    printf("[bpf_loader_demo]      (gdb) attach <UML_MAIN_PID>\n");
    printf("[bpf_loader_demo]      (gdb) break bpf_check\n");
    printf("[bpf_loader_demo]      (gdb) cont\n");
    printf("[bpf_loader_demo]\n");
    printf("[bpf_loader_demo] 3. Trigger the BPF load (in another HOST terminal):\n");
    printf("[bpf_loader_demo]      touch <path-to-uml-rootfs>/tmp/uml_go\n");
    printf("[bpf_loader_demo]\n");
    printf("[bpf_loader_demo] GDB will stop at bpf_check() in kernel/bpf/verifier.c\n");
    printf("[bpf_loader_demo]\n");
    fflush(stdout);

    /* Create ready file */
    unlink(READY_FILE);
    fd = open(READY_FILE, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        write(fd, "ready\n", 6);
        close(fd);
        printf("[bpf_loader_demo] Created ready file: %s\n", READY_FILE);
    }

    /* Remove any stale go file */
    unlink(GO_FILE);

    printf("[bpf_loader_demo] Polling for trigger file: %s\n", GO_FILE);
    printf("[bpf_loader_demo] (touch <path-to-uml-rootfs>/tmp/uml_go to trigger)\n");
    fflush(stdout);

    /* Poll for go file - non-blocking, GDB-friendly */
    while (1) {
        if (stat(GO_FILE, &st) == 0) {
            printf("[bpf_loader_demo] Trigger file found! Loading BPF program...\n");
            fflush(stdout);
            break;
        }
        nanosleep(&ts, NULL);
    }

    /* Load BPF program - this triggers bpf_check() in the verifier */
    printf("[bpf_loader_demo]\n");
    printf("[bpf_loader_demo] === LOADING BPF PROGRAM ===\n");
    printf("[bpf_loader_demo] Calling bpf(BPF_PROG_LOAD)...\n");
    fflush(stdout);

    memset(log_buf, 0, sizeof(log_buf));
    memset(&attr, 0, sizeof(attr));
    attr.prog_type    = BPF_PROG_TYPE_SOCKET_FILTER;
    attr.insns        = (uint64_t)(uintptr_t)prog;
    attr.insn_cnt     = sizeof(prog) / sizeof(prog[0]);
    attr.license      = (uint64_t)(uintptr_t)license;
    attr.log_buf      = (uint64_t)(uintptr_t)log_buf;
    attr.log_size     = sizeof(log_buf);
    attr.log_level    = 2;

    fd = bpf_syscall(BPF_PROG_LOAD, &attr, sizeof(attr));
    if (fd < 0) {
        fprintf(stderr, "[bpf_loader_demo] BPF_PROG_LOAD failed: %s (errno=%d)\n",
                strerror(errno), errno);
        if (log_buf[0])
            fprintf(stderr, "Verifier log:\n%s\n", log_buf);
    } else {
        printf("[bpf_loader_demo] BPF program loaded successfully, fd=%d\n", fd);
        if (log_buf[0])
            printf("Verifier log:\n%s\n", log_buf);
        close(fd);
    }

    printf("[bpf_loader_demo]\n");
    printf("[bpf_loader_demo] === DEMO COMPLETE ===\n");
    printf("[bpf_loader_demo] Sleeping. GDB can inspect state.\n");
    fflush(stdout);

    /* Sleep so GDB can inspect */
    while (1) {
        sleep(60);
    }

    return 0;
}
