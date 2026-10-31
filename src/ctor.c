// dylib 加载时自动执行的入口。
//
// Swift 没有 __attribute__((constructor)) 的语法，而全局 let 是懒加载的
// （没人访问就永不执行），所以必须用 C 这一层来保证「一旦被 dlopen 就跑」。
//
// TrollFools / 越狱注入都只负责把 dylib 塞进进程，不会主动调任何函数，
// 因此这个 constructor 是整个注入方案的自举点。
#include <stddef.h>

extern void qfspeed_inject_entry(void);

__attribute__((constructor))
static void qfspeed_ctor(void) {
    qfspeed_inject_entry();
}
