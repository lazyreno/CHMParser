//
//  Header.h
//  CHMSwift
//
//  Created by edy on 2025/4/29.
//

/*
 #ifndef CHMBridge_h
 #define CHMBridge_h
 
 // 在 Swift 包里暴露给 Swift 使用的C头文件，建议用 #import "xxx.h"，不要用 #include！
 #import "chm_lib.h"
 
 #endif
 **/


#ifndef CHMBridge_h
#define CHMBridge_h

// 判断当前是否为 C++ 编译环境
#ifdef __cplusplus
// 如果是 C++，使用 extern "C" 确保 C 函数在 C++ 环境中不会发生名称修饰（name mangling）
extern "C" {
#endif

// 通过 #include 引入 chm_lib.h
// chm_lib.h 文件中已经声明了所有需要的 C 函数，如 chm_open、chm_close 等
// 所以在这里**不需要再次重复声明这些方法**。
// 只需要确保 chm_lib.h 中的方法声明是正确的，
// 然后在其他文件（如 C 或 Swift 文件）中包含此头文件即可。
// 如果你已经在 chm_lib.h 中声明了这些方法，你无需在这里再重复声明。
#include "chm_lib.h"

/*
 void chm_open(const char *path);
 void chm_close(chmFile *chm);
 // 其他函数声明...
 */

// 通过 #include 引入 chm_lib.h 头文件
// chm_lib.h 中已经包含了所有的 C 函数声明，比如 chm_open、chm_close 等。
// 通过包含 chm_lib.h，编译器会自动找到这些函数声明，并在链接时正确连接到它们的实现。
#include "chm_lib.h"

// 这里不需要再手动声明这些函数，
// 因为在 chm_lib.h 中已经声明了它们，
// 你只需要在需要使用这些函数的文件中包含 chm_lib.h。
// 如果需要，chm_lib.h 会包含例如以下的函数声明：
// void chm_open(const char *path);
// void chm_close(chmFile *chm);
// 其他 C 函数声明...

#ifdef __cplusplus
// 如果是 C++ 环境，结束 extern "C" 块，确保 C++ 编译器正确链接 C 函数
}
#endif

#endif /* CHMBridge_h */
