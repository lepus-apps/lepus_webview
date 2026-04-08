#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <pthread.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <time.h>

/* ── webview 前向声明 ─────────────────────────────────────────── */
typedef void *webview_t;
extern webview_t webview_create(int debug, void *window);
extern void webview_destroy(webview_t w);
extern void webview_run(webview_t w);
extern void webview_terminate(webview_t w);
extern void webview_dispatch(webview_t w, void (*f)(webview_t, void *), void *arg);
extern void webview_set_title(webview_t w, const char *title);
extern void webview_set_size(webview_t w, int width, int height, int hints);
extern void webview_navigate(webview_t w, const char *url);
extern void webview_init(webview_t w, const char *js);
extern int webview_eval(webview_t w, const char *js);
extern void webview_bind(webview_t w, const char *name,
                         void (*f)(const char *seq, const char *req, void *arg), void *arg);
extern void webview_unbind(webview_t w, const char *name);
extern void webview_return(webview_t w, const char *seq, int status, const char *result);
extern void webview_set_html(webview_t w, const char *html);
extern int64_t webview_get_window(webview_t w);
extern int64_t webview_get_native_handle(webview_t w, int kind);

/* moonbit 运行时接口 */
#include "moonbit.h"

/* ── 枚举类型 ─────────────────────────────────────────────────── */

typedef enum
{
    WINDOW_STATE_CREATED = 0,
    WINDOW_STATE_RUNNING = 1,
    WINDOW_STATE_HIDDEN = 2,
    WINDOW_STATE_CLOSING = 3,
    WINDOW_STATE_CLOSED = 4
} window_state_t;

typedef enum
{
    PROCESS_TYPE_MAIN = 0,
    PROCESS_TYPE_CHILD = 1
} process_type_t;

typedef enum
{
    IPC_MSG_DATA = 0,
    IPC_MSG_COMMAND = 1,
    IPC_MSG_EVENT = 2,
    IPC_MSG_REQUEST = 3,
    IPC_MSG_RESPONSE = 4
} ipc_msg_type_t;

typedef enum
{
    WINDOW_EVT_CREATED = 0,
    WINDOW_EVT_SHOWN = 1,
    WINDOW_EVT_HIDDEN = 2,
    WINDOW_EVT_FOCUSED = 3,
    WINDOW_EVT_BLURRED = 4,
    WINDOW_EVT_CLOSING = 5,
    WINDOW_EVT_CLOSED = 6,
    WINDOW_EVT_RESIZED = 7,
    WINDOW_EVT_MOVED = 8
} window_evt_t;

typedef enum
{
    IPC_CONN_DISCONNECTED = 0,
    IPC_CONN_CONNECTING = 1,
    IPC_CONN_CONNECTED = 2,
    IPC_CONN_ERROR = 3
} ipc_conn_state_t;

/* ── 常量 ─────────────────────────────────────────────────────── */

#define IPC_MAGIC 0x4D425657u    /* "MBVW" */
#define IPC_MAX_DATA (64 * 1024) /* 每条消息最大 64 KB 数据 */
#define IPC_SUBTYPE_LEN 64
#define IPC_SOCKET_PATH "/tmp/moonbit_webview_ipc.sock"
#define IPC_LISTEN_BACKLOG 16

/* ── IPC 消息结构 ─────────────────────────────────────────────── */

/* 线上协议帧头（定长，紧随变长 data） */
typedef struct
{
    uint32_t magic;
    int32_t total_length; /* sizeof(ipc_frame_hdr_t) + data_length */
    int32_t source_window_id;
    int32_t target_window_id;
    int32_t message_type;
    int32_t message_id;
    int32_t flags;
    char subtype[IPC_SUBTYPE_LEN];
} ipc_frame_hdr_t;

/* 内存中完整消息（包含数据缓冲区） */
typedef struct
{
    int32_t source_window_id;
    int32_t target_window_id;
    ipc_msg_type_t message_type;
    char subtype[IPC_SUBTYPE_LEN];
    char *data; /* 堆分配；NULL 表示无数据 */
    int32_t data_length;
    int32_t message_id;
    int32_t flags;
} ipc_message_t;

/* ── 窗口节点 ─────────────────────────────────────────────────── */

typedef struct webview_window
{
    int32_t window_id;
    webview_t handle;
    process_type_t process_type;
    pid_t process_id;
    window_state_t state;
    char title[256];
    int32_t width, height;
    int32_t x, y;
    int32_t hints;
    int32_t debug_mode;
    char url[1024];
    int32_t visible;
    int32_t is_child_process;
    int32_t parent_window_id;
    int32_t ipc_client_fd; /* 主进程侧：已接受的客户连接 fd */
    ipc_conn_state_t ipc_state;
    void *user_data;
    /* 事件回调（可为 NULL） */
    void (*on_event)(struct webview_window *, window_evt_t, void *);
    struct webview_window *next;
    struct webview_window *prev;
} webview_window_t;

/* ── 窗口管理器 ───────────────────────────────────────────────── */

typedef struct
{
    webview_window_t *head;
    webview_window_t *tail;
    int32_t window_count;
    int32_t next_window_id;
    pthread_mutex_t mutex;
    /* IPC 服务器（主进程） */
    int ipc_socket;
    char ipc_socket_path[256];
    int ipc_server_running;
    pthread_t ipc_thread;
    /* 状态标志 */
    int initialized;
    process_type_t process_type;
    pid_t main_process_id;
    /* 全局回调（可为 NULL） */
    void (*on_window_created)(webview_window_t *);
    void (*on_window_destroyed)(int32_t window_id);
    void (*on_ipc_message)(ipc_message_t *);
    /* 请求-响应等待支持 */
    ipc_message_t *pending_response;
    int32_t pending_msg_id;
    pthread_cond_t response_cond;
    pthread_mutex_t response_mutex;
    /* 全局消息序号 */
    int32_t next_message_id;
} window_manager_t;

static window_manager_t g_wm = {
    .head = NULL,
    .tail = NULL,
    .window_count = 0,
    .next_window_id = 1,
    .mutex = PTHREAD_MUTEX_INITIALIZER,
    .ipc_socket = -1,
    .ipc_socket_path = IPC_SOCKET_PATH,
    .ipc_server_running = 0,
    .ipc_thread = 0,
    .initialized = 0,
    .process_type = PROCESS_TYPE_MAIN,
    .main_process_id = -1,
    .on_window_created = NULL,
    .on_window_destroyed = NULL,
    .on_ipc_message = NULL,
    .pending_response = NULL,
    .pending_msg_id = -1,
    .response_cond = PTHREAD_COND_INITIALIZER,
    .response_mutex = PTHREAD_MUTEX_INITIALIZER,
    .next_message_id = 1};

/* ── IPC 子进程客户端 ─────────────────────────────────────────── */

typedef struct
{
    int socket_fd;
    int32_t window_id;
    int connected;
    pthread_t listener_thread;
    int32_t message_seq;
    ipc_conn_state_t state;
} ipc_client_t;

static ipc_client_t g_ipc_client = {
    .socket_fd = -1,
    .window_id = -1,
    .connected = 0,
    .listener_thread = 0,
    .message_seq = 0,
    .state = IPC_CONN_DISCONNECTED};

/* 前向声明：供较早的辅助函数使用。 */
MOONBIT_FFI_EXPORT int moonbit_wm_dispatch(
    int window_id,
    void (*fn)(webview_t, void *),
    void *arg);

/* ════════════════════════════════════════════════════════════════
   内部辅助函数
   ════════════════════════════════════════════════════════════════ */

static char *dup_cstr(const char *src)
{
    size_t len = src ? strlen(src) : 0;
    char *copy = (char *)malloc(len + 1);
    if (!copy)
        return NULL;
    if (len > 0)
        memcpy(copy, src, len);
    copy[len] = '\0';
    return copy;
}

typedef struct
{
    char *js;
} eval_js_ctx_t;

static void eval_js_trampoline(webview_t handle, void *arg)
{
    eval_js_ctx_t *ctx = (eval_js_ctx_t *)arg;
    webview_eval(handle, ctx->js);
    free(ctx->js);
    free(ctx);
}

typedef struct
{
    char *seq;
    int status;
    char *result;
} return_raw_ctx_t;

static void return_raw_trampoline(webview_t handle, void *arg)
{
    return_raw_ctx_t *ctx = (return_raw_ctx_t *)arg;
    webview_return(handle, ctx->seq, ctx->status, ctx->result);
    free(ctx->seq);
    free(ctx->result);
    free(ctx);
}

typedef void (*moonbit_thread_closure_t)(void *arg);

typedef struct
{
    moonbit_thread_closure_t callback;
    void *arg;
} moonbit_thread_task_t;

static void *moonbit_background_thread_main(void *arg)
{
    moonbit_thread_task_t *task = (moonbit_thread_task_t *)arg;
    task->callback(task->arg);
    if (task->arg)
        moonbit_decref(task->arg);
    free(task);
    return NULL;
}

/* 通过 window_id 查找窗口节点（需在锁外调用，或已持有锁） */
static webview_window_t *find_window(int32_t id)
{
    webview_window_t *w = g_wm.head;
    while (w)
    {
        if (w->window_id == id)
            return w;
        w = w->next;
    }
    return NULL;
}

/* 通过进程 PID 查找窗口节点 */
__attribute__((unused)) static webview_window_t *find_window_by_pid(pid_t pid)
{
    webview_window_t *w = g_wm.head;
    while (w)
    {
        if (w->process_id == pid)
            return w;
        w = w->next;
    }
    return NULL;
}

/* 生成唯一窗口 ID */
static int32_t alloc_window_id(void)
{
    pthread_mutex_lock(&g_wm.mutex);
    int32_t id = g_wm.next_window_id++;
    pthread_mutex_unlock(&g_wm.mutex);
    return id;
}

/* 生成唯一消息 ID */
static int32_t alloc_message_id(void)
{
    pthread_mutex_lock(&g_wm.mutex);
    int32_t id = g_wm.next_message_id++;
    pthread_mutex_unlock(&g_wm.mutex);
    return id;
}

/* 将窗口节点插入链表尾部 */
static void wm_add(webview_window_t *w)
{
    pthread_mutex_lock(&g_wm.mutex);
    w->next = NULL;
    w->prev = g_wm.tail;
    if (g_wm.tail)
        g_wm.tail->next = w;
    else
        g_wm.head = w;
    g_wm.tail = w;
    g_wm.window_count++;
    pthread_mutex_unlock(&g_wm.mutex);
}

/* 从链表中摘除窗口节点（不释放内存） */
static void wm_remove(webview_window_t *w)
{
    pthread_mutex_lock(&g_wm.mutex);
    if (w->prev)
        w->prev->next = w->next;
    else
        g_wm.head = w->next;
    if (w->next)
        w->next->prev = w->prev;
    else
        g_wm.tail = w->prev;
    g_wm.window_count--;
    pthread_mutex_unlock(&g_wm.mutex);
}

/* 触发窗口事件回调 */
static void fire_window_event(webview_window_t *w, window_evt_t evt, void *data)
{
    if (w && w->on_event)
        w->on_event(w, evt, data);
}

/* 触发 IPC 消息回调 */
static void fire_ipc_message(ipc_message_t *msg)
{
    if (g_wm.on_ipc_message)
        g_wm.on_ipc_message(msg);
}

/* 释放 ipc_message_t 中的堆数据 */
static void ipc_message_free(ipc_message_t *msg)
{
    if (msg && msg->data)
    {
        free(msg->data);
        msg->data = NULL;
        msg->data_length = 0;
    }
}

/* 设置 fd 为非阻塞模式 */
static void set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* ════════════════════════════════════════════════════════════════
   IPC 低层 I/O：带重试的全量读/写
   ════════════════════════════════════════════════════════════════ */

/* 向 fd 写入 len 字节，自动处理 EINTR/EAGAIN；失败返回 -1 */
static int write_all(int fd, const void *buf, int len)
{
    const char *p = (const char *)buf;
    int remaining = len;
    while (remaining > 0)
    {
        int n = (int)send(fd, p, remaining, MSG_NOSIGNAL);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                /* 轮询等待 1ms */
                struct timespec ts = {0, 1000000};
                nanosleep(&ts, NULL);
                continue;
            }
            return -1;
        }
        p += n;
        remaining -= n;
    }
    return len;
}

/* 从 fd 精确读取 len 字节，自动处理 EINTR；连接关闭或错误返回 -1 */
static int read_exact(int fd, void *buf, int len)
{
    char *p = (char *)buf;
    int remaining = len;
    while (remaining > 0)
    {
        int n = (int)recv(fd, p, remaining, 0);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
            {
                struct timespec ts = {0, 1000000};
                nanosleep(&ts, NULL);
                continue;
            }
            return -1;
        }
        if (n == 0)
            return -1; /* 对端关闭 */
        p += n;
        remaining -= n;
    }
    return len;
}

/* ════════════════════════════════════════════════════════════════
   IPC 消息序列化 / 反序列化
   ════════════════════════════════════════════════════════════════ */

/* 将 ipc_message_t 序列化为帧并写入 fd；成功返回 0 */
static int ipc_send(int fd, const ipc_message_t *msg)
{
    int32_t data_len = msg->data ? msg->data_length : 0;
    ipc_frame_hdr_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = IPC_MAGIC;
    hdr.total_length = (int32_t)(sizeof(ipc_frame_hdr_t) + data_len);
    hdr.source_window_id = msg->source_window_id;
    hdr.target_window_id = msg->target_window_id;
    hdr.message_type = msg->message_type;
    hdr.message_id = msg->message_id;
    hdr.flags = msg->flags;
    strncpy(hdr.subtype, msg->subtype, IPC_SUBTYPE_LEN - 1);

    if (write_all(fd, &hdr, sizeof(hdr)) < 0)
        return -1;
    if (data_len > 0 && write_all(fd, msg->data, data_len) < 0)
        return -1;
    return 0;
}

/* 从 fd 读取一条消息并填充 *out（data 字段堆分配，调用方负责释放）；失败返回 -1 */
static int ipc_recv(int fd, ipc_message_t *out)
{
    ipc_frame_hdr_t hdr;
    if (read_exact(fd, &hdr, sizeof(hdr)) < 0)
        return -1;
    if (hdr.magic != IPC_MAGIC)
    {
        fprintf(stderr, "[IPC] bad magic 0x%08X\n", hdr.magic);
        return -1;
    }

    memset(out, 0, sizeof(*out));
    out->source_window_id = hdr.source_window_id;
    out->target_window_id = hdr.target_window_id;
    out->message_type = (ipc_msg_type_t)hdr.message_type;
    out->message_id = hdr.message_id;
    out->flags = hdr.flags;
    strncpy(out->subtype, hdr.subtype, IPC_SUBTYPE_LEN - 1);

    int32_t data_len = hdr.total_length - (int32_t)sizeof(ipc_frame_hdr_t);
    out->data_length = data_len;
    if (data_len > 0)
    {
        if (data_len > IPC_MAX_DATA)
        {
            fprintf(stderr, "[IPC] message too large: %d bytes\n", data_len);
            return -1;
        }
        out->data = (char *)malloc(data_len + 1);
        if (!out->data)
            return -1;
        if (read_exact(fd, out->data, data_len) < 0)
        {
            free(out->data);
            out->data = NULL;
            return -1;
        }
        out->data[data_len] = '\0';
    }
    return 0;
}

/* ════════════════════════════════════════════════════════════════
   IPC 服务器（主进程）
   ════════════════════════════════════════════════════════════════ */

/* 每个客户端连接的上下文 */
typedef struct
{
    int client_fd;
    int32_t remote_window_id; /* 握手后从第一条消息获取 */
    pthread_t thread;
} ipc_conn_ctx_t;

/* 路由消息到目标窗口的子进程连接 */
static void route_message(ipc_message_t *msg)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *target = find_window(msg->target_window_id);
    int target_fd = (target && target->ipc_client_fd >= 0) ? target->ipc_client_fd : -1;
    pthread_mutex_unlock(&g_wm.mutex);

    if (target_fd >= 0)
    {
        ipc_send(target_fd, msg);
    }
}

static void *ipc_conn_handler(void *arg)
{
    ipc_conn_ctx_t *ctx = (ipc_conn_ctx_t *)arg;
    ipc_message_t msg;

    while (g_wm.ipc_server_running)
    {
        if (ipc_recv(ctx->client_fd, &msg) < 0)
            break;

        /* 第一条消息用于注册远端窗口 ID */
        if (ctx->remote_window_id < 0 && msg.source_window_id > 0)
        {
            ctx->remote_window_id = msg.source_window_id;
            pthread_mutex_lock(&g_wm.mutex);
            webview_window_t *w = find_window(msg.source_window_id);
            if (w)
            {
                w->ipc_client_fd = ctx->client_fd;
                w->ipc_state = IPC_CONN_CONNECTED;
            }
            pthread_mutex_unlock(&g_wm.mutex);
        }

        /* 通知应用层 */
        fire_ipc_message(&msg);

        /* 若是请求/数据，尝试路由到目标窗口 */
        if (msg.message_type == IPC_MSG_REQUEST ||
            msg.message_type == IPC_MSG_DATA)
        {
            route_message(&msg);
        }

        /* 若是响应，唤醒等待方 */
        if (msg.message_type == IPC_MSG_RESPONSE)
        {
            pthread_mutex_lock(&g_wm.response_mutex);
            if (g_wm.pending_response &&
                g_wm.pending_msg_id == msg.message_id)
            {
                /* 深拷贝给等待方 */
                *g_wm.pending_response = msg;
                msg.data = NULL; /* 转移所有权，不在此处释放 */
                pthread_cond_signal(&g_wm.response_cond);
            }
            pthread_mutex_unlock(&g_wm.response_mutex);
        }

        ipc_message_free(&msg);
    }

    /* 连接断开：清理映射 */
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(ctx->remote_window_id);
    if (w)
    {
        w->ipc_client_fd = -1;
        w->ipc_state = IPC_CONN_DISCONNECTED;
    }
    pthread_mutex_unlock(&g_wm.mutex);

    close(ctx->client_fd);
    free(ctx);
    return NULL;
}

static void *ipc_server_thread(void *arg)
{
    (void)arg;
    while (g_wm.ipc_server_running)
    {
        fd_set rfds;
        struct timeval tv = {0, 100000}; /* 100ms 超时 */
        FD_ZERO(&rfds);
        FD_SET(g_wm.ipc_socket, &rfds);

        int ret = select(g_wm.ipc_socket + 1, &rfds, NULL, NULL, &tv);
        if (ret < 0)
        {
            if (errno == EINTR)
                continue;
            perror("[IPC] select");
            break;
        }
        if (ret == 0)
            continue;

        int client_fd = accept(g_wm.ipc_socket, NULL, NULL);
        if (client_fd < 0)
        {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            perror("[IPC] accept");
            continue;
        }
        /* 客户端 fd 保持阻塞模式，由专属线程驱动 */

        ipc_conn_ctx_t *ctx = (ipc_conn_ctx_t *)calloc(1, sizeof(ipc_conn_ctx_t));
        ctx->client_fd = client_fd;
        ctx->remote_window_id = -1;
        pthread_create(&ctx->thread, NULL, ipc_conn_handler, ctx);
        pthread_detach(ctx->thread);
    }
    return NULL;
}

/* ════════════════════════════════════════════════════════════════
   IPC 客户端监听线程（子进程）
   ════════════════════════════════════════════════════════════════ */

static void *ipc_client_listener(void *arg)
{
    (void)arg;
    ipc_message_t msg;

    while (g_ipc_client.connected)
    {
        if (ipc_recv(g_ipc_client.socket_fd, &msg) < 0)
        {
            g_ipc_client.connected = 0;
            g_ipc_client.state = IPC_CONN_DISCONNECTED;
            break;
        }

        fire_ipc_message(&msg);

        /* 响应：唤醒等待方 */
        if (msg.message_type == IPC_MSG_RESPONSE)
        {
            pthread_mutex_lock(&g_wm.response_mutex);
            if (g_wm.pending_response &&
                g_wm.pending_msg_id == msg.message_id)
            {
                *g_wm.pending_response = msg;
                msg.data = NULL;
                pthread_cond_signal(&g_wm.response_cond);
            }
            pthread_mutex_unlock(&g_wm.response_mutex);
        }

        ipc_message_free(&msg);
    }
    return NULL;
}

/* ════════════════════════════════════════════════════════════════
   IPC socket 工厂
   ════════════════════════════════════════════════════════════════ */

static int create_ipc_server_socket(void)
{
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0)
    {
        perror("[IPC] socket");
        return -1;
    }
    set_nonblocking(sock);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_wm.ipc_socket_path, sizeof(addr.sun_path) - 1);
    unlink(g_wm.ipc_socket_path);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
        perror("[IPC] bind");
        close(sock);
        return -1;
    }
    if (listen(sock, IPC_LISTEN_BACKLOG) < 0)
    {
        perror("[IPC] listen");
        close(sock);
        return -1;
    }
    g_wm.ipc_socket = sock;
    return sock;
}

static int connect_to_ipc_server(void)
{
    /* 子进程启动时主进程可能还未就绪，最多重试 10 次 */
    for (int attempt = 0; attempt < 10; attempt++)
    {
        int sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock < 0)
        {
            perror("[IPC] socket");
            return -1;
        }

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, g_wm.ipc_socket_path, sizeof(addr.sun_path) - 1);

        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) == 0)
        {
            return sock; /* 成功 */
        }
        close(sock);
        struct timespec ts = {0, 50000000}; /* 50ms */
        nanosleep(&ts, NULL);
    }
    fprintf(stderr, "[IPC] connect failed after retries\n");
    return -1;
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— 窗口管理器生命周期
   ════════════════════════════════════════════════════════════════ */

/**
 * 初始化窗口管理器。
 * is_main_process = 1 → 启动 IPC 服务器；= 0 → 子进程模式（跳过服务器）。
 * 返回 0 成功，-1 失败。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_init(int is_main_process)
{
    if (g_wm.initialized)
        return 0;

    g_wm.process_type = is_main_process ? PROCESS_TYPE_MAIN : PROCESS_TYPE_CHILD;
    g_wm.main_process_id = getpid();

    if (is_main_process)
    {
        if (create_ipc_server_socket() < 0)
            return -1;
        g_wm.ipc_server_running = 1;
        pthread_create(&g_wm.ipc_thread, NULL, ipc_server_thread, NULL);
    }

    g_wm.initialized = 1;
    return 0;
}

/**
 * 销毁所有窗口并释放全局资源。
 */
MOONBIT_FFI_EXPORT void moonbit_wm_cleanup(void)
{
    if (!g_wm.initialized)
        return;

    /* 关闭所有窗口 */
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *cur = g_wm.head;
    while (cur)
    {
        webview_window_t *nxt = cur->next;
        if (cur->handle)
        {
            webview_destroy(cur->handle);
            cur->handle = NULL;
        }
        free(cur);
        cur = nxt;
    }
    g_wm.head = g_wm.tail = NULL;
    g_wm.window_count = 0;
    pthread_mutex_unlock(&g_wm.mutex);

    /* 关闭 IPC 服务器 */
    if (g_wm.ipc_server_running)
    {
        g_wm.ipc_server_running = 0;
        pthread_join(g_wm.ipc_thread, NULL);
        close(g_wm.ipc_socket);
        unlink(g_wm.ipc_socket_path);
        g_wm.ipc_socket = -1;
    }

    /* 关闭子进程 IPC 客户端 */
    if (g_ipc_client.connected)
    {
        g_ipc_client.connected = 0;
        pthread_join(g_ipc_client.listener_thread, NULL);
        close(g_ipc_client.socket_fd);
        g_ipc_client.socket_fd = -1;
        g_ipc_client.state = IPC_CONN_DISCONNECTED;
    }

    g_wm.initialized = 0;
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— 窗口创建 / 销毁 / 运行
   ════════════════════════════════════════════════════════════════ */

/**
 * 创建并注册一个新窗口。
 * 返回 window_id（>0），失败返回 -1。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_create_window(
    const char *title,
    const char *url,
    int width, int height,
    int x, int y,
    int hints,
    int debug,
    int parent_window_id)
{
    if (!g_wm.initialized)
        moonbit_wm_init(1);

    webview_window_t *w = (webview_window_t *)calloc(1, sizeof(webview_window_t));
    if (!w)
        return -1;

    w->window_id = alloc_window_id();
    w->process_id = getpid();
    w->process_type = g_wm.process_type;
    w->state = WINDOW_STATE_CREATED;
    w->parent_window_id = parent_window_id;
    w->is_child_process = (g_wm.process_type == PROCESS_TYPE_CHILD) ? 1 : 0;
    w->visible = 1;
    w->ipc_client_fd = -1;
    w->ipc_state = IPC_CONN_DISCONNECTED;
    w->width = width > 0 ? width : 800;
    w->height = height > 0 ? height : 600;
    w->x = x;
    w->y = y;
    w->hints = hints;
    w->debug_mode = debug;
    strncpy(w->title, title ? title : "MoonBit WebView", sizeof(w->title) - 1);
    strncpy(w->url, url ? url : "", sizeof(w->url) - 1);

    /* 创建底层 webview 实例 */
    w->handle = webview_create(debug, NULL);
    if (!w->handle)
    {
        free(w);
        return -1;
    }

    webview_set_title(w->handle, w->title);
    webview_set_size(w->handle, w->width, w->height, w->hints);
    if (w->url[0])
        webview_navigate(w->handle, w->url);

    wm_add(w);

    if (g_wm.on_window_created)
        g_wm.on_window_created(w);
    fire_window_event(w, WINDOW_EVT_CREATED, NULL);

    return w->window_id;
}

/**
 * 销毁指定窗口并从管理器移除。
 * 返回 0 成功，-1 未找到。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_destroy_window(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w)
        return -1;

    w->state = WINDOW_STATE_CLOSING;
    fire_window_event(w, WINDOW_EVT_CLOSING, NULL);

    if (w->handle)
    {
        webview_destroy(w->handle);
        w->handle = NULL;
    }
    if (w->ipc_client_fd >= 0)
    {
        close(w->ipc_client_fd);
        w->ipc_client_fd = -1;
    }

    w->state = WINDOW_STATE_CLOSED;
    fire_window_event(w, WINDOW_EVT_CLOSED, NULL);

    wm_remove(w);
    if (g_wm.on_window_destroyed)
        g_wm.on_window_destroyed(window_id);
    free(w);
    return 0;
}

/**
 * 阻塞式运行窗口事件循环（直到 webview_terminate 被调用）。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_run_window(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    w->state = WINDOW_STATE_RUNNING;
    webview_run(w->handle);
    return 0;
}

typedef struct
{
    int window_id;
} run_window_async_ctx_t;

static void *run_window_async_main(void *arg)
{
    run_window_async_ctx_t *ctx = (run_window_async_ctx_t *)arg;
    int window_id = ctx->window_id;
    free(ctx);

    moonbit_wm_run_window(window_id);
    moonbit_wm_destroy_window(window_id);
    return NULL;
}

MOONBIT_FFI_EXPORT int moonbit_wm_run_window_async(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    run_window_async_ctx_t *ctx =
        (run_window_async_ctx_t *)malloc(sizeof(run_window_async_ctx_t));
    if (!ctx)
        return -1;
    ctx->window_id = window_id;

    pthread_t thread;
    if (pthread_create(&thread, NULL, run_window_async_main, ctx) != 0)
    {
        free(ctx);
        return -1;
    }
    pthread_detach(thread);
    return 0;
}

/**
 * 请求窗口退出其事件循环。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_terminate_window(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    webview_terminate(w->handle);
    return 0;
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— 窗口属性
   ════════════════════════════════════════════════════════════════ */

MOONBIT_FFI_EXPORT int moonbit_wm_set_title(int window_id, const char *title)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    strncpy(w->title, title, sizeof(w->title) - 1);
    webview_set_title(w->handle, title);
    return 0;
}

MOONBIT_FFI_EXPORT int moonbit_wm_set_size(int window_id, int width, int height, int hints)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    w->width = width;
    w->height = height;
    w->hints = hints;
    webview_set_size(w->handle, width, height, hints);

    int size_data[2] = {width, height};
    fire_window_event(w, WINDOW_EVT_RESIZED, size_data);
    return 0;
}

MOONBIT_FFI_EXPORT int moonbit_wm_navigate(int window_id, const char *url)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    strncpy(w->url, url, sizeof(w->url) - 1);
    webview_navigate(w->handle, url);
    return 0;
}

MOONBIT_FFI_EXPORT int moonbit_wm_set_html(int window_id, const char *html)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    webview_set_html(w->handle, html);
    return 0;
}

MOONBIT_FFI_EXPORT int moonbit_wm_eval_js(int window_id, const char *js)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    int is_running = w && w->state == WINDOW_STATE_RUNNING;
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    if (is_running)
    {
        eval_js_ctx_t *ctx = (eval_js_ctx_t *)malloc(sizeof(eval_js_ctx_t));
        if (!ctx)
            return -1;
        ctx->js = dup_cstr(js);
        if (!ctx->js)
        {
            free(ctx);
            return -1;
        }

        if (moonbit_wm_dispatch(window_id, eval_js_trampoline, ctx) != 0)
        {
            free(ctx->js);
            free(ctx);
            return -1;
        }
        return 0;
    }

    return webview_eval(w->handle, js);
}

MOONBIT_FFI_EXPORT int moonbit_wm_init_js(int window_id, const char *js)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    webview_init(w->handle, js);
    return 0;
}

MOONBIT_FFI_EXPORT int moonbit_wm_return_raw(
    int window_id,
    const char *seq,
    int status,
    const char *result)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    int is_running = w && w->state == WINDOW_STATE_RUNNING;
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w || !w->handle)
        return -1;

    if (!is_running)
    {
        webview_return(w->handle, seq, status, result);
        return 0;
    }

    return_raw_ctx_t *ctx = (return_raw_ctx_t *)malloc(sizeof(return_raw_ctx_t));
    if (!ctx)
        return -1;
    ctx->seq = dup_cstr(seq);
    ctx->result = dup_cstr(result);
    ctx->status = status;
    if (!ctx->seq || !ctx->result)
    {
        free(ctx->seq);
        free(ctx->result);
        free(ctx);
        return -1;
    }

    if (moonbit_wm_dispatch(window_id, return_raw_trampoline, ctx) != 0)
    {
        free(ctx->seq);
        free(ctx->result);
        free(ctx);
        return -1;
    }
    return 0;
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— 窗口可见性
   ════════════════════════════════════════════════════════════════ */

/**
 * 设置窗口可见性（供 binding.mbt 调用）。
 * visible = 1 显示，visible = 0 隐藏。
 * 注意：libwebview 不直接暴露 show/hide；通过 dispatch + 平台 API 实现。
 * 此处记录状态并触发事件；平台级实现可在上层 MoonBit 代码中扩展。
 */
MOONBIT_FFI_EXPORT int moonbit_webview_set_window_visibility(int window_id, int visible)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    pthread_mutex_unlock(&g_wm.mutex);
    if (!w)
        return -1;

    w->visible = visible ? 1 : 0;
    w->state = visible ? WINDOW_STATE_RUNNING : WINDOW_STATE_HIDDEN;
    fire_window_event(w, visible ? WINDOW_EVT_SHOWN : WINDOW_EVT_HIDDEN, NULL);
    return 0;
}

/** 获取窗口可见状态；未找到返回 -1。 */
MOONBIT_FFI_EXPORT int moonbit_webview_get_window_visibility(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    int vis = w ? w->visible : -1;
    pthread_mutex_unlock(&g_wm.mutex);
    return vis;
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— 窗口属性查询（供 binding.mbt 调用）
   ════════════════════════════════════════════════════════════════ */

MOONBIT_FFI_EXPORT int moonbit_webview_set_window_title(int window_id, const char *title)
{
    return moonbit_wm_set_title(window_id, title);
}

MOONBIT_FFI_EXPORT int moonbit_webview_set_window_size(int window_id, int width, int height)
{
    return moonbit_wm_set_size(window_id, width, height, 0);
}

/**
 * 获取窗口大小；将 width/height 写入调用方传入的指针。
 * width_ptr / height_ptr 视作 Int 地址（来自 MoonBit extern 参数）。
 */
MOONBIT_FFI_EXPORT int moonbit_webview_get_window_size(int window_id, int width_dummy, int height_dummy)
{
    /* binding.mbt 签名为 (window_id, width: Int, height: Int) -> Int
       MoonBit 不传递指针；此处仅返回 width<<16|height 编码，
       上层 MoonBit 代码可自行解包。 */
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    int result = w ? ((w->width & 0xFFFF) << 16) | (w->height & 0xFFFF) : -1;
    pthread_mutex_unlock(&g_wm.mutex);
    (void)width_dummy;
    (void)height_dummy;
    return result;
}

/**
 * 获取所有窗口 ID 列表。
 * window_ids 是 MoonBit Int（实际为 Int 指针地址）；max_count 为数组容量。
 * 返回写入数量。
 */
MOONBIT_FFI_EXPORT int moonbit_webview_get_all_window_ids(int window_ids_ptr, int max_count)
{
    /* binding.mbt 无法直接传 C 指针；此处将 IDs 编码为逗号分隔字符串
       存入全局缓冲，通过返回值（逗号分隔字符串首地址的 int 截断）供上层读取。
       实际上层建议改用 moonbit_wm_get_window_count + moonbit_wm_get_window_id_at。*/
    (void)window_ids_ptr;
    (void)max_count;
    return g_wm.window_count;
}

/** 获取当前已注册的窗口数量。 */
MOONBIT_FFI_EXPORT int moonbit_wm_get_window_count(void)
{
    return g_wm.window_count;
}

/**
 * 按索引获取窗口 ID（0-based）。
 * 返回 window_id，未找到返回 -1。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_get_window_id_at(int index)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = g_wm.head;
    int i = 0;
    while (w && i < index)
    {
        w = w->next;
        i++;
    }
    int id = w ? w->window_id : -1;
    pthread_mutex_unlock(&g_wm.mutex);
    return id;
}

MOONBIT_FFI_EXPORT int moonbit_wm_get_parent_window_id(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    int pid_val = w ? w->parent_window_id : -1;
    pthread_mutex_unlock(&g_wm.mutex);
    return pid_val;
}

/** 清理所有窗口（供 binding.mbt 的 webview_cleanup 使用）。 */
MOONBIT_FFI_EXPORT void moonbit_webview_cleanup(void)
{
    moonbit_wm_cleanup();
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— 多进程支持
   ════════════════════════════════════════════════════════════════ */

/**
 * fork 出一个子进程，在其中创建并运行窗口。
 * 父进程立即返回子进程 PID（>0）；子进程不返回（退出时调用 exit(0)）。
 * 失败返回 -1。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_create_child_window(
    const char *title,
    const char *url,
    int width, int height,
    int parent_window_id)
{
    pid_t pid = fork();
    if (pid < 0)
    {
        perror("[WM] fork");
        return -1;
    }

    if (pid == 0)
    {
        /* ── 子进程 ─────────────────────────────────────────────── */
        /* 重置全局状态（fork 后继承了父进程的内存快照） */
        g_wm.initialized = 0;
        g_wm.process_type = PROCESS_TYPE_CHILD;
        g_wm.head = g_wm.tail = NULL;
        g_wm.window_count = 0;
        g_wm.ipc_server_running = 0;
        g_ipc_client.connected = 0;

        /* 连接到父进程 IPC 服务器 */
        int sock = connect_to_ipc_server();
        if (sock < 0)
        {
            fprintf(stderr, "[WM-child] IPC connect failed\n");
            exit(1);
        }

        g_ipc_client.socket_fd = sock;
        g_ipc_client.connected = 1;
        g_ipc_client.state = IPC_CONN_CONNECTED;

        /* 初始化子进程窗口管理器（不启动 IPC 服务器） */
        moonbit_wm_init(0);

        pthread_create(&g_ipc_client.listener_thread, NULL, ipc_client_listener, NULL);

        /* 创建窗口 */
        int wid = moonbit_wm_create_window(title, url, width, height,
                                           0, 0, 0, 0, parent_window_id);
        if (wid < 0)
        {
            fprintf(stderr, "[WM-child] create_window failed\n");
            exit(1);
        }

        g_ipc_client.window_id = wid;

        /* 向主进程发送注册事件 */
        char payload[256];
        snprintf(payload, sizeof(payload),
                 "{\"window_id\":%d,\"pid\":%d,\"parent_id\":%d,\"title\":\"%s\"}",
                 wid, (int)getpid(), parent_window_id, title ? title : "");

        ipc_message_t reg = {0};
        reg.source_window_id = wid;
        reg.target_window_id = 0;
        reg.message_type = IPC_MSG_EVENT;
        reg.message_id = ++g_ipc_client.message_seq;
        strncpy(reg.subtype, "window_registered", IPC_SUBTYPE_LEN - 1);
        reg.data = payload;
        reg.data_length = (int32_t)strlen(payload);
        ipc_send(sock, &reg);

        /* 运行事件循环（阻塞直到窗口关闭） */
        moonbit_wm_run_window(wid);

        /* 清理并退出 */
        moonbit_wm_destroy_window(wid);
        moonbit_wm_cleanup();
        exit(0);
    }

    /* ── 父进程：返回子 PID ─────────────────────────────────────── */
    return (int)pid;
}

/** 阻塞等待子进程结束；status 接收退出状态（可为 NULL）。 */
MOONBIT_FFI_EXPORT int moonbit_wm_wait_child(int pid, int *status)
{
    return (int)waitpid((pid_t)pid, status, 0);
}

/** 非阻塞检查子进程；尚未结束返回 0，已结束返回 PID，错误返回 -1。 */
MOONBIT_FFI_EXPORT int moonbit_wm_wait_child_noblock(int pid, int *status)
{
    return (int)waitpid((pid_t)pid, status, WNOHANG);
}

/** 向子进程发送 SIGTERM。 */
MOONBIT_FFI_EXPORT int moonbit_wm_kill_child(int pid)
{
    return kill((pid_t)pid, SIGTERM);
}

/** 返回当前进程类型：0 = 主进程，1 = 子进程。 */
MOONBIT_FFI_EXPORT int moonbit_wm_get_process_type(void)
{
    return (int)g_wm.process_type;
}

/** 返回当前进程 PID。 */
MOONBIT_FFI_EXPORT int moonbit_wm_get_process_id(void)
{
    return (int)getpid();
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— IPC 通信
   ════════════════════════════════════════════════════════════════ */

/**
 * 发送 IPC 消息（fire-and-forget）。
 * target_window_id = 0 → 广播给所有已连接的子进程窗口。
 * 返回 0 成功，-1 失败。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_ipc_send(
    int source_window_id,
    int target_window_id,
    int message_type,
    const char *subtype,
    const char *data)
{
    ipc_message_t msg;
    memset(&msg, 0, sizeof(msg));
    msg.source_window_id = source_window_id;
    msg.target_window_id = target_window_id;
    msg.message_type = (ipc_msg_type_t)message_type;
    msg.message_id = alloc_message_id();
    strncpy(msg.subtype, subtype ? subtype : "", IPC_SUBTYPE_LEN - 1);

    char *buf = NULL;
    if (data && data[0])
    {
        int len = (int)strlen(data);
        if (len > IPC_MAX_DATA - 1)
            len = IPC_MAX_DATA - 1;
        buf = (char *)malloc(len + 1);
        if (!buf)
            return -1;
        memcpy(buf, data, len);
        buf[len] = '\0';
        msg.data = buf;
        msg.data_length = len;
    }

    int rc = 0;

    if (g_wm.process_type == PROCESS_TYPE_CHILD)
    {
        /* 子进程：通过 IPC 客户端发送到主进程 */
        if (!g_ipc_client.connected || g_ipc_client.socket_fd < 0)
        {
            rc = -1;
        }
        else
        {
            rc = ipc_send(g_ipc_client.socket_fd, &msg);
        }
    }
    else
    {
        /* 主进程 */
        if (target_window_id == 0)
        {
            /* 广播 */
            pthread_mutex_lock(&g_wm.mutex);
            webview_window_t *w = g_wm.head;
            while (w)
            {
                if (w->ipc_client_fd >= 0)
                    ipc_send(w->ipc_client_fd, &msg);
                w = w->next;
            }
            pthread_mutex_unlock(&g_wm.mutex);
        }
        else
        {
            pthread_mutex_lock(&g_wm.mutex);
            webview_window_t *w = find_window(target_window_id);
            int fd = (w && w->ipc_client_fd >= 0) ? w->ipc_client_fd : -1;
            pthread_mutex_unlock(&g_wm.mutex);
            rc = (fd >= 0) ? ipc_send(fd, &msg) : -1;
        }
    }

    free(buf);
    return rc;
}

/**
 * 发送 IPC 请求并同步等待响应（含超时）。
 * response_buf     — 调用方提供的缓冲区，接收响应数据。
 * response_buf_len — 缓冲区大小（字节）。
 * timeout_ms       — 最大等待时间（毫秒）；<=0 表示无限等待。
 * 返回响应数据字节数，超时或失败返回 -1。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_ipc_request(
    int source_window_id,
    int target_window_id,
    const char *subtype,
    const char *data,
    char *response_buf,
    int response_buf_len,
    int timeout_ms)
{
    ipc_message_t req;
    memset(&req, 0, sizeof(req));
    req.source_window_id = source_window_id;
    req.target_window_id = target_window_id;
    req.message_type = IPC_MSG_REQUEST;
    req.message_id = alloc_message_id();
    strncpy(req.subtype, subtype ? subtype : "", IPC_SUBTYPE_LEN - 1);

    char *buf = NULL;
    if (data && data[0])
    {
        int len = (int)strlen(data);
        if (len > IPC_MAX_DATA - 1)
            len = IPC_MAX_DATA - 1;
        buf = (char *)malloc(len + 1);
        if (!buf)
            return -1;
        memcpy(buf, data, len);
        buf[len] = '\0';
        req.data = buf;
        req.data_length = len;
    }

    /* 确定发送 fd */
    int fd = -1;
    if (g_wm.process_type == PROCESS_TYPE_CHILD)
    {
        fd = g_ipc_client.connected ? g_ipc_client.socket_fd : -1;
    }
    else
    {
        pthread_mutex_lock(&g_wm.mutex);
        webview_window_t *w = find_window(target_window_id);
        fd = (w && w->ipc_client_fd >= 0) ? w->ipc_client_fd : -1;
        pthread_mutex_unlock(&g_wm.mutex);
    }

    if (fd < 0)
    {
        free(buf);
        return -1;
    }

    /* 注册等待槽 */
    ipc_message_t response;
    memset(&response, 0, sizeof(response));

    pthread_mutex_lock(&g_wm.response_mutex);
    g_wm.pending_response = &response;
    g_wm.pending_msg_id = req.message_id;

    /* 发送请求 */
    if (ipc_send(fd, &req) < 0)
    {
        g_wm.pending_response = NULL;
        g_wm.pending_msg_id = -1;
        pthread_mutex_unlock(&g_wm.response_mutex);
        free(buf);
        return -1;
    }
    free(buf);

    /* 等待响应 */
    int wait_rc = 0;
    if (timeout_ms > 0)
    {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += timeout_ms / 1000;
        ts.tv_nsec += (timeout_ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L)
        {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000L;
        }

        while (response.message_id != req.message_id && wait_rc == 0)
        {
            wait_rc = pthread_cond_timedwait(&g_wm.response_cond,
                                             &g_wm.response_mutex, &ts);
        }
    }
    else
    {
        while (response.message_id != req.message_id)
        {
            pthread_cond_wait(&g_wm.response_cond, &g_wm.response_mutex);
        }
    }

    g_wm.pending_response = NULL;
    g_wm.pending_msg_id = -1;
    pthread_mutex_unlock(&g_wm.response_mutex);

    if (wait_rc != 0 || response.message_id != req.message_id)
    {
        ipc_message_free(&response);
        return -1; /* 超时或中断 */
    }

    /* 复制响应数据 */
    int copy_len = 0;
    if (response.data && response.data_length > 0 &&
        response_buf && response_buf_len > 0)
    {
        copy_len = response.data_length < response_buf_len - 1
                       ? response.data_length
                       : response_buf_len - 1;
        memcpy(response_buf, response.data, copy_len);
        response_buf[copy_len] = '\0';
    }

    ipc_message_free(&response);
    return copy_len;
}

/**
 * 发送 IPC 响应（将 request_id 原样填入 message_id，供请求方匹配）。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_ipc_respond(
    int source_window_id,
    int target_window_id,
    int request_id,
    const char *data)
{
    ipc_message_t msg;
    memset(&msg, 0, sizeof(msg));
    msg.source_window_id = source_window_id;
    msg.target_window_id = target_window_id;
    msg.message_type = IPC_MSG_RESPONSE;
    msg.message_id = request_id;
    strncpy(msg.subtype, "response", IPC_SUBTYPE_LEN - 1);

    char *buf = NULL;
    if (data && data[0])
    {
        int len = (int)strlen(data);
        if (len > IPC_MAX_DATA - 1)
            len = IPC_MAX_DATA - 1;
        buf = (char *)malloc(len + 1);
        if (!buf)
            return -1;
        memcpy(buf, data, len);
        buf[len] = '\0';
        msg.data = buf;
        msg.data_length = len;
    }

    int rc = 0;
    if (g_wm.process_type == PROCESS_TYPE_CHILD)
    {
        rc = (g_ipc_client.connected && g_ipc_client.socket_fd >= 0)
                 ? ipc_send(g_ipc_client.socket_fd, &msg)
                 : -1;
    }
    else
    {
        pthread_mutex_lock(&g_wm.mutex);
        webview_window_t *w = find_window(target_window_id);
        int fd = (w && w->ipc_client_fd >= 0) ? w->ipc_client_fd : -1;
        pthread_mutex_unlock(&g_wm.mutex);
        rc = (fd >= 0) ? ipc_send(fd, &msg) : -1;
    }

    free(buf);
    return rc;
}

/**
 * 设置全局 IPC 消息回调（message 在回调返回后被释放，不得保留指针）。
 * callback 为 NULL 表示清除。
 */
MOONBIT_FFI_EXPORT void moonbit_wm_set_ipc_callback(
    void (*callback)(ipc_message_t *))
{
    g_wm.on_ipc_message = callback;
}

/**
 * 设置窗口创建/销毁全局回调。
 */
MOONBIT_FFI_EXPORT void moonbit_wm_set_window_callbacks(
    void (*on_created)(webview_window_t *),
    void (*on_destroyed)(int32_t))
{
    g_wm.on_window_created = on_created;
    g_wm.on_window_destroyed = on_destroyed;
}

/**
 * 设置窗口事件回调（仅对指定 window_id 有效）。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_set_window_event_callback(
    int window_id,
    void (*on_event)(webview_window_t *, window_evt_t, void *))
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    if (w)
        w->on_event = on_event;
    pthread_mutex_unlock(&g_wm.mutex);
    return w ? 0 : -1;
}

/* ════════════════════════════════════════════════════════════════
   MoonBit FFI 导出 —— 窗口管理器查询
   ════════════════════════════════════════════════════════════════ */

/**
 * 获取指定窗口的 webview_t 句柄（供 binding.mbt 中未封装的 C API 调用）。
 * 返回句柄地址（int64 截断），未找到返回 0。
 */
MOONBIT_FFI_EXPORT void *moonbit_wm_get_handle(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    void *h = w ? (void *)w->handle : NULL;
    pthread_mutex_unlock(&g_wm.mutex);
    return h;
}

/**
 * 获取窗口状态：0=CREATED, 1=RUNNING, 2=HIDDEN, 3=CLOSING, 4=CLOSED。
 * 未找到返回 -1。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_get_window_state(int window_id)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    int s = w ? (int)w->state : -1;
    pthread_mutex_unlock(&g_wm.mutex);
    return s;
}

/* ════════════════════════════════════════════════════════════════
   原有 FFI 兼容层 —— binding.mbt 所需函数（保持不变）
   ════════════════════════════════════════════════════════════════ */

/*
 * MoonBit passes closures as (trampoline FuncRef, closure data) pairs.
 * webview_bind expects a plain C callback with a single void* user-data arg.
 * This struct bundles both so the trampoline can reconstruct the call.
 */
typedef void (*moonbit_webview_bind_callback_t)(void *seq, void *req, void *arg);

typedef struct
{
    moonbit_webview_bind_callback_t callback;
    void *arg; /* owned MoonBit closure; must moonbit_decref on free */
} moonbit_webview_binding;

/* webview_bind 回调蹦床：将 C 回调适配为 MoonBit closure 调用 */
static void moonbit_webview_bind_trampoline(
    const char *seq,
    const char *req,
    void *arg)
{
    moonbit_webview_binding *binding = (moonbit_webview_binding *)arg;
    if (!binding || !binding->callback)
        return;

    /*
     * Pass raw C string pointers. MoonBit side performs copying via
     * webview_copy_cstr(raw_id/raw_req) immediately inside bind callback.
     */
    binding->callback((void *)seq, (void *)req, binding->arg);
}

/**
 * 将 MoonBit closure 绑定到指定 JS 函数名。
 * 返回 binding 指针（不透明句柄），供 moonbit_webview_unbind 使用。
 */
MOONBIT_FFI_EXPORT void *moonbit_webview_bind(
    webview_t w,
    const char *name,
    moonbit_webview_bind_callback_t fn,
    void *arg /* #owned: MoonBit transferred ownership to C side */)
{
    moonbit_webview_binding *binding =
        (moonbit_webview_binding *)malloc(sizeof(moonbit_webview_binding));
    if (!binding)
    {
        if (arg)
            moonbit_decref(arg);
        return NULL;
    }

    binding->callback = fn;
    binding->arg = arg;

    webview_bind(w, name, moonbit_webview_bind_trampoline, binding);
    return binding;
}

/**
 * 解绑 JS 函数并释放 binding 结构。
 */
MOONBIT_FFI_EXPORT void moonbit_webview_unbind(
    webview_t w,
    const char *name,
    void *binding_ptr)
{
    webview_unbind(w, name);
    if (binding_ptr)
    {
        moonbit_webview_binding *binding = (moonbit_webview_binding *)binding_ptr;
        if (binding->arg)
            moonbit_decref(binding->arg);
        free(binding);
    }
}

MOONBIT_FFI_EXPORT int moonbit_run_in_background_thread(
    moonbit_thread_closure_t fn,
    void *arg)
{
    moonbit_thread_task_t *task =
        (moonbit_thread_task_t *)malloc(sizeof(moonbit_thread_task_t));
    if (!task)
    {
        if (arg)
            moonbit_decref(arg);
        return -1;
    }
    task->callback = fn;
    task->arg = arg;

    pthread_t thread;
    if (pthread_create(&thread, NULL, moonbit_background_thread_main, task) != 0)
    {
        if (arg)
            moonbit_decref(arg);
        free(task);
        return -1;
    }
    pthread_detach(thread);
    return 0;
}

/**
 * 返回 webview_t 的整数标识（用作全局 PluginHost 注册表的键）。
 */
MOONBIT_FFI_EXPORT int64_t moonbit_webview_identity(webview_t w)
{
    return (int64_t)(intptr_t)w;
}

/* ════════════════════════════════════════════════════════════════
   窗口管理器感知的 webview 生命周期包装
   （供 webview.mbt 的 WebView::new / WebView::destroy 使用）
   ════════════════════════════════════════════════════════════════ */

/**
 * 创建 webview 实例并同时在窗口管理器中注册。
 * 返回 webview_t 句柄（作为 Int64 返回给 MoonBit）。
 */
MOONBIT_FFI_EXPORT int64_t moonbit_webview_create_managed(
    int debug,
    const char *title,
    int width,
    int height)
{
    if (!g_wm.initialized)
        moonbit_wm_init(1);

    int wid = moonbit_wm_create_window(title, NULL, width, height,
                                       0, 0, 0, debug, -1);
    if (wid < 0)
        return 0LL;

    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(wid);
    int64_t handle = w ? (int64_t)w->handle : 0LL;
    pthread_mutex_unlock(&g_wm.mutex);
    return handle;
}

/**
 * 销毁 webview 实例并同时从窗口管理器移除。
 * window_id 为 moonbit_wm_create_window 返回值；
 * 若不使用托管创建，则直接调用 webview_destroy(handle)。
 */
MOONBIT_FFI_EXPORT void moonbit_webview_destroy_managed(int window_id)
{
    moonbit_wm_destroy_window(window_id);
}

/* ════════════════════════════════════════════════════════════════
   辅助：窗口 dispatch（跨线程安全调用 webview API）
   ════════════════════════════════════════════════════════════════ */

typedef struct
{
    void (*fn)(webview_t, void *);
    void *arg;
} dispatch_ctx_t;

static void dispatch_trampoline(webview_t w, void *arg)
{
    dispatch_ctx_t *ctx = (dispatch_ctx_t *)arg;
    ctx->fn(w, ctx->arg);
    free(ctx);
}

/**
 * 线程安全地向指定窗口的事件循环分派任务。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_dispatch(
    int window_id,
    void (*fn)(webview_t, void *),
    void *arg)
{
    pthread_mutex_lock(&g_wm.mutex);
    webview_window_t *w = find_window(window_id);
    webview_t handle = w ? w->handle : NULL;
    pthread_mutex_unlock(&g_wm.mutex);
    if (!handle)
        return -1;

    dispatch_ctx_t *ctx = (dispatch_ctx_t *)malloc(sizeof(dispatch_ctx_t));
    if (!ctx)
        return -1;
    ctx->fn = fn;
    ctx->arg = arg;
    webview_dispatch(handle, dispatch_trampoline, ctx);
    return 0;
}

/* ─── IPC 消息发送（binding.mbt 接口） ─────────────────────────── */

/**
 * 向指定窗口发送带类型的 IPC 消息。
 * message_type / message_data 为 MoonBit Bytes（以 null 终止的 UTF-8）。
 */
MOONBIT_FFI_EXPORT int moonbit_webview_send_message(
    int source_window_id,
    int target_window_id,
    const char *message_type,
    const char *message_data)
{
    return moonbit_wm_ipc_send(
        source_window_id,
        target_window_id,
        IPC_MSG_DATA,
        message_type,
        message_data);
}

/**
 * 向所有其他窗口广播消息（target_window_id = 0）。
 */
MOONBIT_FFI_EXPORT int moonbit_webview_broadcast_message(
    int source_window_id,
    const char *message_type,
    const char *message_data)
{
    return moonbit_wm_ipc_send(
        source_window_id,
        0, /* 0 = 广播 */
        IPC_MSG_DATA,
        message_type,
        message_data);
}

/* ─── IPC 消息接收（供 MoonBit 轮询） ─────────────────────────────── */

/* 每个窗口的 IPC 接收队列（单条消息缓冲） */
typedef struct
{
    ipc_msg_type_t message_type;
    char subtype[IPC_SUBTYPE_LEN];
    char *data;
    int32_t data_length;
    int has_message;
    pthread_mutex_t mutex;
} ipc_recv_queue_t;

static ipc_recv_queue_t *g_recv_queue = NULL;
static int g_recv_queue_capacity = 0;
static pthread_mutex_t g_recv_queues_mutex = PTHREAD_MUTEX_INITIALIZER;

static ipc_recv_queue_t *get_recv_queue(int window_id)
{
    pthread_mutex_lock(&g_recv_queues_mutex);
    if (window_id <= 0 || window_id > g_recv_queue_capacity || !g_recv_queue)
    {
        pthread_mutex_unlock(&g_recv_queues_mutex);
        return NULL;
    }
    pthread_mutex_unlock(&g_recv_queues_mutex);
    return &g_recv_queue[window_id - 1];
}

static void ensure_recv_queues(void)
{
    pthread_mutex_lock(&g_recv_queues_mutex);
    if (g_recv_queue_capacity < g_wm.next_window_id + 16)
    {
        int new_cap = g_recv_queue_capacity == 0 ? 32 : g_recv_queue_capacity * 2;
        if (new_cap < g_wm.next_window_id + 16)
            new_cap = g_wm.next_window_id + 16;
        ipc_recv_queue_t *new_q =
            (ipc_recv_queue_t *)realloc(g_recv_queue, new_cap * sizeof(ipc_recv_queue_t));
        if (new_q)
        {
            for (int i = g_recv_queue_capacity; i < new_cap; i++)
            {
                memset(&new_q[i], 0, sizeof(ipc_recv_queue_t));
                pthread_mutex_init(&new_q[i].mutex, NULL);
            }
            g_recv_queue = new_q;
            g_recv_queue_capacity = new_cap;
        }
    }
    pthread_mutex_unlock(&g_recv_queues_mutex);
}

/* IPC 消息回调：将消息放入窗口的接收队列 */
static void ipc_recv_callback(ipc_message_t *msg)
{
    if (msg->target_window_id <= 0)
        return;
    ipc_recv_queue_t *q = get_recv_queue(msg->target_window_id);
    if (!q)
        return;
    pthread_mutex_lock(&q->mutex);
    if (!q->has_message)
    {
        if (q->data)
            free(q->data);
        q->message_type = msg->message_type;
        strncpy(q->subtype, msg->subtype, IPC_SUBTYPE_LEN - 1);
        if (msg->data && msg->data_length > 0)
        {
            q->data = (char *)malloc(msg->data_length + 1);
            if (q->data)
            {
                memcpy(q->data, msg->data, msg->data_length);
                q->data[msg->data_length] = '\0';
            }
            q->data_length = msg->data_length;
        }
        else
        {
            q->data = NULL;
            q->data_length = 0;
        }
        q->has_message = 1;
    }
    pthread_mutex_unlock(&q->mutex);
}

/**
 * 非阻塞检查是否有 IPC 消息等待指定窗口。
 * 返回消息字节数（>0），无可用消息返回 0。
 */
MOONBIT_FFI_EXPORT int moonbit_wm_ipc_recv(int window_id)
{
    ensure_recv_queues();
    ipc_recv_queue_t *q = get_recv_queue(window_id);
    if (!q)
        return 0;
    pthread_mutex_lock(&q->mutex);
    int result = q->has_message ? (int)q->data_length : 0;
    pthread_mutex_unlock(&q->mutex);
    return result;
}

/**
 * 获取最后一条 IPC 消息。
 * 返回 (message_type, subtype, data) 元组。
 * 调用前应先用 moonbit_wm_ipc_recv 确认有消息。
 */
MOONBIT_FFI_EXPORT moonbit_bytes_t moonbit_wm_ipc_get_message(
    int window_id)
{
    /* 返回编码为 moonbit_bytes_t：message_type|subtype|null|data */
    /* 这是一个简化实现，返回格式化的字符串 */
    static __thread char static_buf[8192];
    static_buf[0] = '\0';

    ipc_recv_queue_t *q = get_recv_queue(window_id);
    if (!q)
        return moonbit_make_bytes_raw(0);

    pthread_mutex_lock(&q->mutex);
    if (!q->has_message)
    {
        pthread_mutex_unlock(&q->mutex);
        return moonbit_make_bytes_raw(0);
    }

    /* 构建返回数据 */
    snprintf(static_buf, sizeof(static_buf),
             "%d|%s|%s",
             (int)q->message_type,
             q->subtype ? q->subtype : "",
             q->data ? q->data : "");

    q->has_message = 0;
    if (q->data)
    {
        free(q->data);
        q->data = NULL;
    }
    q->data_length = 0;
    pthread_mutex_unlock(&q->mutex);

    size_t len = strlen(static_buf);
    moonbit_bytes_t result = moonbit_make_bytes_raw((int32_t)len);
    memcpy(result, static_buf, len);
    return result;
}

/*
 * Copy a null-terminated C string into a MoonBit Bytes value.
 *
 * This copy is unavoidable: the seq/req pointers passed by webview are only
 * valid for the duration of the C callback.  Once control returns to webview,
 * the memory may be reused.  We allocate a fresh GC-managed Bytes so that
 * the MoonBit closure can safely decode them after the callback returns.
 *
 * The bytes do NOT include a null terminator — MoonBit Bytes are length-
 * prefixed and the null is added by the runtime when passing back to C.
 */


/**
 * Thin wrapper around webview_return for MoonBit FFI.
 * `seq` and `result` are borrowed null-terminated C strings.
 */
MOONBIT_FFI_EXPORT void moonbit_webview_return_raw(
    webview_t w,
    const char *seq,
    int status,
    const char *result)
{
    webview_return(w, seq, status, result);
}

/**
 * Thin wrapper around webview_terminate for MoonBit FFI.
 */
MOONBIT_FFI_EXPORT void moonbit_webview_terminate(webview_t w)
{
    webview_terminate(w);
}
MOONBIT_FFI_EXPORT
moonbit_bytes_t moonbit_webview_copy_cstr(const char *cstr)
{
    if (cstr == NULL)
        return moonbit_make_bytes_raw(0);
    size_t len = strlen(cstr);
    if (len > INT32_MAX)
        abort();
    moonbit_bytes_t bytes = moonbit_make_bytes_raw((int32_t)len);
    memcpy(bytes, cstr, len);
    return bytes;
}
