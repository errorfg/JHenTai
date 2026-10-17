// openjdk/mobile's Zero build for iOS leaves out three definitions that the
// JVM's shared code refers to on Apple's arm64: they are in
// os_cpu/bsd_aarch64, which a Zero build does not compile. They switch
// memory between writable and executable for generated code; Zero generates
// none, and os::current_thread_enable_wx does nothing on iOS, so they only
// need to exist, with these values.

enum WXMode { WXWrite = 0, WXExec = 1, WXArmedForWrite = 2 };

WXMode DefaultWXWriteMode = WXWrite;

class os {
 public:
  static void thread_wx_enable_write_impl();

 private:
  static __thread bool _jit_exec_enabled;
};

__thread bool os::_jit_exec_enabled = false;

void os::thread_wx_enable_write_impl() {}
