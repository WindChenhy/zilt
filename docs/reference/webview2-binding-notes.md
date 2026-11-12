# WebView2 手写 Zig COM 绑定 — ABI 参考资料

> 数据来源（全部为亲手打开文件后逐字提取，非凭印象）：
>
> - **官方 SDK**: NuGet 包 `Microsoft.Web.WebView2` **v1.0.4314.35**（最新稳定版，2026-11 下载），
>   头文件 `build/native/include/WebView2.h`（MIDL 生成，69222 行）。
>   本地解包副本：`C:/Users/Mrchen/.zcode/workspace/draft-8980e86b-c6bf-4c54-8641-e17ca19a06c2/.scratch/webview2-nuget/`
> - **webview/webview** tag **`0.12.0`**，文件 `core/include/webview/webview.h`（内建 loader，第 3222–3520 行附近）
>   及 `compatibility/mingw/include/EventToken.h`。
> - **本机实测**（Windows 10.0.26200 x64，已装 Evergreen Runtime 156.0.4314.58）：
>   `reg query` 与 `objdump -p` 直接验证注册表键值与 DLL 导出表。
>
> 所有行号均指对应来源文件中的实际行号，可直接复查。

---

## A. IID（GUID）表

来源：`build/native/include/WebView2.h` 中每个接口的 `MIDL_INTERFACE("...")` 行。
行号 = `MIDL_INTERFACE` 所在行。

| 接口 | IID（字符串形式，可逐字使用） | WebView2.h 行号 |
|---|---|---|
| IUnknown（标准） | `{00000000-0000-0000-C000-000000000046}` | （Windows SDK 定义） |
| ICoreWebView2Environment | `{B96D755E-0319-4E92-A296-23436F46A1FC}` | 44437 |
| ICoreWebView2Environment2 | `{41F3632B-5EF4-404F-AD82-2D606C5A9A21}` | 44749 |
| ICoreWebView2Controller | `{4D00C0D1-9434-4EB6-8078-8697A560334F}` | 39227 |
| ICoreWebView2 | `{76ECEACB-0462-4D94-AC83-423A6793775E}` | 3035 |
| ICoreWebView2Settings | `{E562E4F0-D7FA-43AC-8D71-C05150499F00}` | 64220 |
| ICoreWebView2EnvironmentOptions | `{2FDE08A8-1E9A-4766-8C05-95A9CEB9D1C5}` | 48595 |
| ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler | `{4E8A3389-C9D8-4BD2-B6B5-124FEE6CC14D}` | 44351 |
| ICoreWebView2CreateCoreWebView2ControllerCompletedHandler | `{6C4819F3-C9B7-4260-8127-C9F5BDE7F68C}` | 44663 |
| ICoreWebView2ExecuteScriptCompletedHandler | `{49511172-CC67-4BCA-9923-137112F4C4CC}` | 5078 |
| ICoreWebView2WebMessageReceivedEventHandler | `{57213F19-00E6-49FA-8E07-898EA01ECBD2}` | 4734 |
| ICoreWebView2WebMessageReceivedEventArgs | `{0F99A40C-E962-4207-9E92-E3D542EFF849}` | 67876 |
| ICoreWebView2WebResourceRequestedEventHandler | `{AB00B74C-15F1-4646-80E8-E76341D25D71}` | 4820 |
| ICoreWebView2WebResourceRequestedEventArgs | `{453E667F-12C7-49D4-BE6D-DDBE7956F57A}` | 68241 |
| ICoreWebView2WebResourceRequest | `{97055CD4-512C-4264-8B5F-E3F446CEA6A5}` | 68091 |
| ICoreWebView2WebResourceResponse | `{AAFCC94F-FA27-48FD-97DF-830EF75AAEC9}` | 68494 |

C 风格初始化形式（与头文件 `EXTERN_C __declspec(selectany) const IID IID_xxx = {...}` 一致，
例如 ICoreWebView2 在 WebView2.h 第 3032 行）：

```c
/* ICoreWebView2 */
{0x76eceacb,0x0462,0x4d94,{0xac,0x83,0x42,0x3a,0x67,0x93,0x77,0x5e}}
/* ICoreWebView2Environment */
{0xb96d755e,0x0319,0x4e92,{0xa2,0x96,0x23,0x43,0x6f,0x46,0xa1,0xfc}}
/* ICoreWebView2Environment2 */
{0x41f3632b,0x5ef4,0x404f,{0xad,0x82,0x2d,0x60,0x6c,0x5a,0x9a,0x21}}
/* ICoreWebView2Controller */
{0x4d00c0d1,0x9434,0x4eb6,{0x80,0x78,0x86,0x97,0xa5,0x60,0x33,0x4f}}
/* ICoreWebView2Settings */
{0xe562e4f0,0xd7fa,0x43ac,{0x8d,0x71,0xc0,0x51,0x50,0x49,0x9f,0x00}}
/* ICoreWebView2EnvironmentOptions */
{0x2fde08a8,0x1e9a,0x4766,{0x8c,0x05,0x95,0xa9,0xce,0xb9,0xd1,0xc5}}
/* ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler */
{0x4e8a3389,0xc9d8,0x4bd2,{0xb6,0xb5,0x12,0x4f,0xee,0x6c,0xc1,0x4d}}
/* ICoreWebView2CreateCoreWebView2ControllerCompletedHandler */
{0x6c4819f3,0xc9b7,0x4260,{0x81,0x27,0xc9,0xf5,0xbd,0xe7,0xf6,0x8c}}
/* ICoreWebView2ExecuteScriptCompletedHandler */
{0x49511172,0xcc67,0x4bca,{0x99,0x23,0x13,0x71,0x12,0xf4,0xc4,0xcc}}
/* ICoreWebView2WebMessageReceivedEventHandler */
{0x57213f19,0x00e6,0x49fa,{0x8e,0x07,0x89,0x8e,0xa0,0x1e,0xcb,0xd2}}
/* ICoreWebView2WebMessageReceivedEventArgs */
{0x0f99a40c,0xe962,0x4207,{0x9e,0x92,0xe3,0xd5,0x42,0xef,0xf8,0x49}}
/* ICoreWebView2WebResourceRequestedEventHandler */
{0xab00b74c,0x15f1,0x4646,{0x80,0xe8,0xe7,0x63,0x41,0xd2,0x5d,0x71}}
/* ICoreWebView2WebResourceRequestedEventArgs */
{0x453e667f,0x12c7,0x49d4,{0xbe,0x6d,0xdd,0xbe,0x79,0x56,0xf5,0x7a}}
/* ICoreWebView2WebResourceRequest */
{0x97055cd4,0x512c,0x4264,{0x8b,0x5f,0xe3,0xf4,0x46,0xce,0xa6,0xa5}}
/* ICoreWebView2WebResourceResponse */
{0xaafcc94f,0xfa27,0x48fd,{0x97,0xdf,0x83,0x0e,0xf7,0x5a,0xae,0xc9}}
```

GUID 二进制布局（16 字节，小端按字段）：`Data1: u32, Data2: u16, Data3: u16, Data4: [8]u8`。
字符串形式按 RFC 4122 顺序（大端展示），抄字符串时注意 Zig 侧解析顺序。

webview 0.12.0 自身代码中用到的 IID（`core/include/webview/webview.h` 第 3260–3290 行，可直接比对）：
ControllerCompletedHandler `{6C4819F3-…}`、EnvironmentCompletedHandler `{4E8A3389-…}`、
PermissionRequestedEventHandler `{15E1C6A3-C72A-4DF3-91D7-D097FBEC6BFD}`、
WebMessageReceivedEventHandler `{57213F19-…}`、
AddScriptToExecuteOnDocumentCreatedCompletedHandler `{B99369F3-9B11-47B5-BC6F-8E7895FCEA17}`。

---

## B. vtable 顺序（ABI 生死攸关，逐字核对自头文件声明顺序）

规则（适用于本节所有接口）：

- 每个 COM 对象开头是 `IUnknown` 三件套：槽 0 `QueryInterface(REFIID riid, void **ppvObject) -> HRESULT`，
  槽 1 `AddRef() -> ULONG`，槽 2 `Release() -> ULONG`。
- 所有方法均带隐式第一参数 `This`（即 Zig 中的 `*self`）。
- 修饰：C++ 类声明用 `virtual HRESULT STDMETHODCALLTYPE ...`；C 风格 `lpVtbl` 结构用
  `HRESULT (STDMETHODCALLTYPE *Name)(Interface *This, ...)`。`STDMETHODCALLTYPE == __stdcall`
  （x64 上编译器忽略 __stdcall，统一用 Microsoft x64 调用约定；x86 上为 stdcall）。
- C++ 类声明的虚函数顺序 == MIDL 生成的 `XXXVtbl` 成员顺序 == 运行时真实 vtable 槽位。
  本节方法名与参数逐字取自各接口 `MIDL_INTERFACE` 块到结束 `};` 之间的声明顺序。
- 类型说明：`LPWSTR = wchar_t*`（调用方用 `CoTaskMemFree` 释放）、`LPCWSTR/PCWSTR = const wchar_t*`、
  `BOOL = c_int(4 字节)`、`UINT32 = u32`、`HRESULT = c_int(4 字节)`、`ULONG = u32`、`double = f64`。
  `EventRegistrationToken = extern struct { value: i64 }`（8 字节；见 Windows SDK `eventtoken.h` 与
  webview `compatibility/mingw/include/EventToken.h`，后者原文 `typedef struct EventRegistrationToken { int64_t value; }`）。
- 返回 `LPWSTR*` 的属性（[retval][out]）成功后由调用方 `CoTaskMemFree`。

### B.1 ICoreWebView2Environment（槽 3–7，共 5 个自有方法）

来源：WebView2.h 第 44437 行 `MIDL_INTERFACE` 起（C++ 声明块）。

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | CreateCoreWebView2Controller | `HRESULT (ICoreWebView2Environment *This, HWND parentWindow, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *handler)` |
| 4 | CreateWebResourceResponse | `HRESULT (This, IStream *content, int statusCode, LPCWSTR reasonPhrase, LPCWSTR headers, ICoreWebView2WebResourceResponse **response)` |
| 5 | get_BrowserVersionString | `HRESULT (This, LPWSTR *versionInfo)` |
| 6 | add_NewBrowserVersionAvailable | `HRESULT (This, ICoreWebView2NewBrowserVersionAvailableEventHandler *eventHandler, EventRegistrationToken *token)` |
| 7 | remove_NewBrowserVersionAvailable | `HRESULT (This, EventRegistrationToken token)` |

（派生接口 ICoreWebView2Environment2 在此之上追加 1 个方法
`CreateWebResourceRequest(LPCWSTR uri, LPCWSTR Method, IStream *postData, LPCWSTR Headers, ICoreWebView2WebResourceRequest **value)`，见第 44749 行起的声明块。）

### B.2 ICoreWebView2Controller（槽 3–25，共 23 个自有方法）

来源：WebView2.h 第 39227 行 `MIDL_INTERFACE` 起（方法声明 39230–39302，`};` 在 39304）。

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | get_IsVisible | `HRESULT (This, BOOL *isVisible)` |
| 4 | put_IsVisible | `HRESULT (This, BOOL isVisible)` |
| 5 | get_Bounds | `HRESULT (This, RECT *bounds)` |
| 6 | put_Bounds | `HRESULT (This, RECT bounds)` |
| 7 | get_ZoomFactor | `HRESULT (This, double *zoomFactor)` |
| 8 | put_ZoomFactor | `HRESULT (This, double zoomFactor)` |
| 9 | add_ZoomFactorChanged | `HRESULT (This, ICoreWebView2ZoomFactorChangedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 10 | remove_ZoomFactorChanged | `HRESULT (This, EventRegistrationToken token)` |
| 11 | SetBoundsAndZoomFactor | `HRESULT (This, RECT bounds, double zoomFactor)` |
| 12 | MoveFocus | `HRESULT (This, COREWEBVIEW2_MOVE_FOCUS_REASON reason)` |
| 13 | add_MoveFocusRequested | `HRESULT (This, ICoreWebView2MoveFocusRequestedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 14 | remove_MoveFocusRequested | `HRESULT (This, EventRegistrationToken token)` |
| 15 | add_GotFocus | `HRESULT (This, ICoreWebView2FocusChangedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 16 | remove_GotFocus | `HRESULT (This, EventRegistrationToken token)` |
| 17 | add_LostFocus | `HRESULT (This, ICoreWebView2FocusChangedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 18 | remove_LostFocus | `HRESULT (This, EventRegistrationToken token)` |
| 19 | add_AcceleratorKeyPressed | `HRESULT (This, ICoreWebView2AcceleratorKeyPressedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 20 | remove_AcceleratorKeyPressed | `HRESULT (This, EventRegistrationToken token)` |
| 21 | get_ParentWindow | `HRESULT (This, HWND *parentWindow)` |
| 22 | put_ParentWindow | `HRESULT (This, HWND parentWindow)` |
| 23 | NotifyParentWindowPositionChanged | `HRESULT (This)` |
| 24 | Close | `HRESULT (This)` |
| 25 | get_CoreWebView2 | `HRESULT (This, ICoreWebView2 **coreWebView2)` |

### B.3 ICoreWebView2（槽 3–60，共 58 个自有方法；`MIDL_INTERFACE` 第 3035 行，方法声明 3039–3230，`};` 在 3234）

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | get_Settings | `HRESULT (This, ICoreWebView2Settings **settings)` |
| 4 | get_Source | `HRESULT (This, LPWSTR *uri)` |
| 5 | Navigate | `HRESULT (This, LPCWSTR uri)` |
| 6 | NavigateToString | `HRESULT (This, LPCWSTR htmlContent)` |
| 7 | add_NavigationStarting | `HRESULT (This, ICoreWebView2NavigationStartingEventHandler *eventHandler, EventRegistrationToken *token)` |
| 8 | remove_NavigationStarting | `HRESULT (This, EventRegistrationToken token)` |
| 9 | add_ContentLoading | `HRESULT (This, ICoreWebView2ContentLoadingEventHandler *eventHandler, EventRegistrationToken *token)` |
| 10 | remove_ContentLoading | `HRESULT (This, EventRegistrationToken token)` |
| 11 | add_SourceChanged | `HRESULT (This, ICoreWebView2SourceChangedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 12 | remove_SourceChanged | `HRESULT (This, EventRegistrationToken token)` |
| 13 | add_HistoryChanged | `HRESULT (This, ICoreWebView2HistoryChangedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 14 | remove_HistoryChanged | `HRESULT (This, EventRegistrationToken token)` |
| 15 | add_NavigationCompleted | `HRESULT (This, ICoreWebView2NavigationCompletedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 16 | remove_NavigationCompleted | `HRESULT (This, EventRegistrationToken token)` |
| 17 | add_FrameNavigationStarting | `HRESULT (This, ICoreWebView2NavigationStartingEventHandler *eventHandler, EventRegistrationToken *token)` |
| 18 | remove_FrameNavigationStarting | `HRESULT (This, EventRegistrationToken token)` |
| 19 | add_FrameNavigationCompleted | `HRESULT (This, ICoreWebView2NavigationCompletedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 20 | remove_FrameNavigationCompleted | `HRESULT (This, EventRegistrationToken token)` |
| 21 | add_ScriptDialogOpening | `HRESULT (This, ICoreWebView2ScriptDialogOpeningEventHandler *eventHandler, EventRegistrationToken *token)` |
| 22 | remove_ScriptDialogOpening | `HRESULT (This, EventRegistrationToken token)` |
| 23 | add_PermissionRequested | `HRESULT (This, ICoreWebView2PermissionRequestedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 24 | remove_PermissionRequested | `HRESULT (This, EventRegistrationToken token)` |
| 25 | add_ProcessFailed | `HRESULT (This, ICoreWebView2ProcessFailedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 26 | remove_ProcessFailed | `HRESULT (This, EventRegistrationToken token)` |
| 27 | AddScriptToExecuteOnDocumentCreated | `HRESULT (This, LPCWSTR javaScript, ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *handler)` |
| 28 | RemoveScriptToExecuteOnDocumentCreated | `HRESULT (This, LPCWSTR id)` |
| 29 | ExecuteScript | `HRESULT (This, LPCWSTR javaScript, ICoreWebView2ExecuteScriptCompletedHandler *handler)` |
| 30 | CapturePreview | `HRESULT (This, COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT imageFormat, IStream *imageStream, ICoreWebView2CapturePreviewCompletedHandler *handler)` |
| 31 | Reload | `HRESULT (This)` |
| 32 | PostWebMessageAsJson | `HRESULT (This, LPCWSTR webMessageAsJson)` |
| 33 | PostWebMessageAsString | `HRESULT (This, LPCWSTR webMessageAsString)` |
| 34 | add_WebMessageReceived | `HRESULT (This, ICoreWebView2WebMessageReceivedEventHandler *handler, EventRegistrationToken *token)` |
| 35 | remove_WebMessageReceived | `HRESULT (This, EventRegistrationToken token)` |
| 36 | CallDevToolsProtocolMethod | `HRESULT (This, LPCWSTR methodName, LPCWSTR parametersAsJson, ICoreWebView2CallDevToolsProtocolMethodCompletedHandler *handler)` |
| 37 | get_BrowserProcessId | `HRESULT (This, UINT32 *value)` |
| 38 | get_CanGoBack | `HRESULT (This, BOOL *canGoBack)` |
| 39 | get_CanGoForward | `HRESULT (This, BOOL *canGoForward)` |
| 40 | GoBack | `HRESULT (This)` |
| 41 | GoForward | `HRESULT (This)` |
| 42 | GetDevToolsProtocolEventReceiver | `HRESULT (This, LPCWSTR eventName, ICoreWebView2DevToolsProtocolEventReceiver **receiver)` |
| 43 | Stop | `HRESULT (This)` |
| 44 | add_NewWindowRequested | `HRESULT (This, ICoreWebView2NewWindowRequestedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 45 | remove_NewWindowRequested | `HRESULT (This, EventRegistrationToken token)` |
| 46 | add_DocumentTitleChanged | `HRESULT (This, ICoreWebView2DocumentTitleChangedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 47 | remove_DocumentTitleChanged | `HRESULT (This, EventRegistrationToken token)` |
| 48 | get_DocumentTitle | `HRESULT (This, LPWSTR *title)` |
| 49 | AddHostObjectToScript | `HRESULT (This, LPCWSTR name, VARIANT *object)` |
| 50 | RemoveHostObjectFromScript | `HRESULT (This, LPCWSTR name)` |
| 51 | OpenDevToolsWindow | `HRESULT (This)` |
| 52 | add_ContainsFullScreenElementChanged | `HRESULT (This, ICoreWebView2ContainsFullScreenElementChangedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 53 | remove_ContainsFullScreenElementChanged | `HRESULT (This, EventRegistrationToken token)` |
| 54 | get_ContainsFullScreenElement | `HRESULT (This, BOOL *containsFullScreenElement)` |
| 55 | add_WebResourceRequested | `HRESULT (This, ICoreWebView2WebResourceRequestedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 56 | remove_WebResourceRequested | `HRESULT (This, EventRegistrationToken token)` |
| 57 | AddWebResourceRequestedFilter | `HRESULT (This, const LPCWSTR uri, const COREWEBVIEW2_WEB_RESOURCE_CONTEXT resourceContext)` |
| 58 | RemoveWebResourceRequestedFilter | `HRESULT (This, const LPCWSTR uri, const COREWEBVIEW2_WEB_RESOURCE_CONTEXT resourceContext)` |
| 59 | add_WindowCloseRequested | `HRESULT (This, ICoreWebView2WindowCloseRequestedEventHandler *eventHandler, EventRegistrationToken *token)` |
| 60 | remove_WindowCloseRequested | `HRESULT (This, EventRegistrationToken token)` |

### B.4 ICoreWebView2Settings（槽 3–20，共 18 个自有方法；`MIDL_INTERFACE` 第 64220 行起）

9 对属性 getter/setter，全部 `BOOL` 类型，顺序如下：

| 槽 | 方法 | 参数类型 |
|---|---|---|
| 3 | get_IsScriptEnabled | `(This, BOOL *isScriptEnabled)` |
| 4 | put_IsScriptEnabled | `(This, BOOL isScriptEnabled)` |
| 5 | get_IsWebMessageEnabled | `(This, BOOL *isWebMessageEnabled)` |
| 6 | put_IsWebMessageEnabled | `(This, BOOL isWebMessageEnabled)` |
| 7 | get_AreDefaultScriptDialogsEnabled | `(This, BOOL *areDefaultScriptDialogsEnabled)` |
| 8 | put_AreDefaultScriptDialogsEnabled | `(This, BOOL areDefaultScriptDialogsEnabled)` |
| 9 | get_IsStatusBarEnabled | `(This, BOOL *isStatusBarEnabled)` |
| 10 | put_IsStatusBarEnabled | `(This, BOOL isStatusBarEnabled)` |
| 11 | get_AreDevToolsEnabled | `(This, BOOL *areDevToolsEnabled)` |
| 12 | put_AreDevToolsEnabled | `(This, BOOL areDevToolsEnabled)` |
| 13 | get_AreDefaultContextMenusEnabled | `(This, BOOL *enabled)` |
| 14 | put_AreDefaultContextMenusEnabled | `(This, BOOL enabled)` |
| 15 | get_AreHostObjectsAllowed | `(This, BOOL *allowed)` |
| 16 | put_AreHostObjectsAllowed | `(This, BOOL allowed)` |
| 17 | get_IsZoomControlEnabled | `(This, BOOL *enabled)` |
| 18 | put_IsZoomControlEnabled | `(This, BOOL enabled)` |
| 19 | get_IsBuiltInErrorPageEnabled | `(This, BOOL *enabled)` |
| 20 | put_IsBuiltInErrorPageEnabled | `(This, BOOL enabled)` |

完整签名均为 `virtual /* [propget]|[propput] */ HRESULT STDMETHODCALLTYPE 名字(参数) = 0;`。

### B.5 ICoreWebView2EnvironmentOptions（槽 3–10，共 8 个自有方法；`MIDL_INTERFACE` 第 48595 行起）

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | get_AdditionalBrowserArguments | `HRESULT (This, LPWSTR *value)` |
| 4 | put_AdditionalBrowserArguments | `HRESULT (This, LPCWSTR value)` |
| 5 | get_Language | `HRESULT (This, LPWSTR *value)` |
| 6 | put_Language | `HRESULT (This, LPCWSTR value)` |
| 7 | get_TargetCompatibleBrowserVersion | `HRESULT (This, LPWSTR *value)` |
| 8 | put_TargetCompatibleBrowserVersion | `HRESULT (This, LPCWSTR value)` |
| 9 | get_AllowSingleSignOnUsingOSPrimaryAccount | `HRESULT (This, BOOL *allow)` |
| 10 | put_AllowSingleSignOnUsingOSPrimaryAccount | `HRESULT (This, BOOL allow)` |

配套 `build/native/include/WebView2EnvironmentOptions.h`（官方 C++ 参考实现）定义
`CORE_WEBVIEW_TARGET_PRODUCT_VERSION L"156.0.4314.35"`（第 31 行）——
自建 EnvironmentOptions 时 `TargetCompatibleBrowserVersion` 需填同 SDK 的版本号。

### B.6 ICoreWebView2WebMessageReceivedEventArgs（槽 3–5；`MIDL_INTERFACE` 第 67876 行起）

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | get_Source | `HRESULT (This, LPWSTR *value)` |
| 4 | get_WebMessageAsJson | `HRESULT (This, LPWSTR *value)` |
| 5 | TryGetWebMessageAsString | `HRESULT (This, LPWSTR *value)` |

### B.7 ICoreWebView2WebResourceRequestedEventArgs（槽 3–7；`MIDL_INTERFACE` 第 68241 行起）

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | get_Request | `HRESULT (This, ICoreWebView2WebResourceRequest **request)` |
| 4 | get_Response | `HRESULT (This, ICoreWebView2WebResourceResponse **response)` |
| 5 | put_Response | `HRESULT (This, ICoreWebView2WebResourceResponse *response)` |
| 6 | GetDeferral | `HRESULT (This, ICoreWebView2Deferral **deferral)` |
| 7 | get_ResourceContext | `HRESULT (This, COREWEBVIEW2_WEB_RESOURCE_CONTEXT *context)` |

### B.8 ICoreWebView2WebResourceRequest（槽 3–9；`MIDL_INTERFACE` 第 68091 行起）

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | get_Uri | `HRESULT (This, LPWSTR *uri)` |
| 4 | put_Uri | `HRESULT (This, LPCWSTR uri)` |
| 5 | get_Method | `HRESULT (This, LPWSTR *method)` |
| 6 | put_Method | `HRESULT (This, LPCWSTR method)` |
| 7 | get_Content | `HRESULT (This, IStream **content)` |
| 8 | put_Content | `HRESULT (This, IStream *content)` |
| 9 | get_Headers | `HRESULT (This, ICoreWebView2HttpRequestHeaders **headers)` |

### B.9 ICoreWebView2WebResourceResponse（槽 3–9；`MIDL_INTERFACE` 第 68494 行起）

| 槽 | 方法 | C 签名 |
|---|---|---|
| 3 | get_Content | `HRESULT (This, IStream **content)` |
| 4 | put_Content | `HRESULT (This, IStream *content)` |
| 5 | get_Headers | `HRESULT (This, ICoreWebView2HttpResponseHeaders **headers)` |
| 6 | get_StatusCode | `HRESULT (This, int *statusCode)` |
| 7 | put_StatusCode | `HRESULT (This, int statusCode)` |
| 8 | get_ReasonPhrase | `HRESULT (This, LPWSTR *reasonPhrase)` |
| 9 | put_ReasonPhrase | `HRESULT (This, LPCWSTR reasonPhrase)` |

### B.10 Handler / EventHandler 的 Invoke

每个 Handler/EventHandler 接口只有槽 3 一个方法 `Invoke`：

| 接口 | Invoke 签名（第 3 槽） | 行号 |
|---|---|---|
| ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler | `HRESULT (This, HRESULT errorCode, ICoreWebView2Environment *result)` | 44355–44357 |
| ICoreWebView2CreateCoreWebView2ControllerCompletedHandler | `HRESULT (This, HRESULT errorCode, ICoreWebView2Controller *result)` | 44667–44669 |
| ICoreWebView2ExecuteScriptCompletedHandler | `HRESULT (This, HRESULT errorCode, LPCWSTR result)` | 5082–5084 |
| ICoreWebView2WebMessageReceivedEventHandler | `HRESULT (This, ICoreWebView2 *sender, ICoreWebView2WebMessageReceivedEventArgs *args)` | 4738–4740 |
| ICoreWebView2WebResourceRequestedEventHandler | `HRESULT (This, ICoreWebView2 *sender, ICoreWebView2WebResourceRequestedEventArgs *args)` | 4824–4826 |

在 Zig 中实现回调：自建对象（vtable = [QI, AddRef, Release, Invoke]），传 `*self` 给 add_*/Create*；
`add_X` 返回的 `EventRegistrationToken` 用于对应 `remove_X`。
注意 `errorCode` 失败时 `result`（回调里的对象/字符串出参）可能为 null，必须判空。

---

## C. 枚举值

来源：WebView2.h 第 2966–2985 行。声明为 `typedef /* [v1_enum] */ enum COREWEBVIEW2_WEB_RESOURCE_CONTEXT {...}`
—— **4 字节枚举**（MSVC 下 C 枚举为 int，MIDL `[v1_enum]` 保证 32 位；Zig 侧用 `u32`/`i32` 传参）。
头文件里写法是累加式（`X = (前一个 + 1)`），下面换算成实际数值：

```c
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL                 = 0,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT            = 1,   // ALL+1
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_STYLESHEET          = 2,   // DOCUMENT+1
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_IMAGE               = 3,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_MEDIA               = 4,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_FONT                = 5,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_SCRIPT              = 6,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_XML_HTTP_REQUEST    = 7,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_FETCH               = 8,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_TEXT_TRACK          = 9,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_EVENT_SOURCE        = 10,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_WEBSOCKET           = 11,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_MANIFEST            = 12,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_SIGNED_EXCHANGE     = 13,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_PING                = 14,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_CSP_VIOLATION_REPORT = 15,
COREWEBVIEW2_WEB_RESOURCE_CONTEXT_OTHER               = 16   // CSP_VIOLATION_REPORT+1
```

**`COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_CONTEXT_*` 不存在。**
本 SDK（1.0.4314.35）中最接近的是位标志枚举 `COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS`
（WebView2.h 第 2997–3003 行，`DEFINE_ENUM_FLAG_OPERATORS` 修饰，可按位或）：

```c
COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_NONE           = 0,
COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_DOCUMENT       = 0x1,
COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_SHARED_WORKER  = 0x2,
COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_SERVICE_WORKER = 0x4,
COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL            = 0xffffffff
```

（它由派生接口 `ICoreWebView2_22` 的 `AddWebResourceRequestedFilterWithRequestSourceKinds` 使用，
与基接口 `AddWebResourceRequestedFilter` 用的 `COREWEBVIEW2_WEB_RESOURCE_CONTEXT` 是两个东西。）

### C.x 其他 ABI 相关宏（Task D 记录项）

**`#define CALLBACK` 不在 WebView2.h 里**（grep 0 命中）。它来自 Windows SDK `minwindef.h`
（已核对 zig 自带 mingw-w64 头 `lib/libc/include/any-windows-any/minwindef.h` 第 86–93 行，与官方 SDK 一致）：

```c
#ifndef CALLBACK
#if defined(_ARM_)
#define CALLBACK            /* ARM32 下为空 */
#else
#define CALLBACK __stdcall  /* x86/x64 下为 __stdcall */
#endif
#endif
```

`STDAPI`（winnt.h 第 472–473 行）：

```c
#define STDAPI    EXTERN_C HRESULT WINAPI
#define STDAPI_(type)  EXTERN_C type WINAPI
/* WINAPI = __stdcall（minwindef.h 第 94–99 行；_ARM_ 下为空） */
```

**五个导出 API 的声明**（WebView2.h 第 3016–3020 行，逐字）：

```c
STDAPI CreateCoreWebView2Environment(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* environmentCreatedHandler);
STDAPI CreateCoreWebView2EnvironmentWithOptions(PCWSTR browserExecutableFolder, PCWSTR userDataFolder, ICoreWebView2EnvironmentOptions* environmentOptions, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* environmentCreatedHandler);
STDAPI GetAvailableCoreWebView2BrowserVersionString(PCWSTR browserExecutableFolder, LPWSTR* versionInfo);
STDAPI CompareBrowserVersions(PCWSTR version1, PCWSTR version2, int* result);
STDAPI GetAvailableCoreWebView2BrowserVersionStringWithOptions(PCWSTR browserExecutableFolder, ICoreWebView2EnvironmentOptions* environmentOptions, LPWSTR* versionInfo);
```

即：展开后每个都是 `extern "C" HRESULT __stdcall`。`CompareBrowserVersions` 语义：
`result < 0` 表示 version1 < version2，`0` 相等，`> 0` 表示 version1 > version2（官方 loader 导出，供版本比较）。
`GetAvailableCoreWebView2BrowserVersionString` 成功时 `*versionInfo` 指向 CoTaskMemAlloc 的字符串（用 CoTaskMemFree 释放）。

---

## D. webview/webview 0.12.0 纯 loader 协议（不依赖 WebView2Loader.dll）

> 来源：`webview-0.12.0/core/include/webview/webview.h`（tarball:
> `https://codeload.github.com/webview/webview/tar.gz/refs/tags/0.12.0`）。
> 注意事项先说清：
>
> 1. **0.12.0 没有独立的 webviewloader.cc 文件**。仓库树（已列）中 Windows 相关实现全部在
>    `core/include/webview/webview.h`（header-only），由宏 `WEBVIEW_MSWEBVIEW2_BUILTIN_IMPL=1`
>    （默认开）启用内建 loader；`WEBVIEW_MSWEBVIEW2_EXPLICIT_LINK=1`（默认与 BUILTIN 相同）时改为显式加载 `WebView2Loader.dll`。
> 2. **0.12.0 全源码 grep 不到 `GetEmbeddedBrowserWebViewData`**。它用的导出名是
>    `CreateWebViewEnvironmentWithOptionsInternal`（下述）。该名亦未见于官方 WebView2Loader.dll 导出表。

### D.1 运行时定位算法（webview 0.12.0 原文逻辑）

关键常量（webview.h 第 3504–3510 行）：

```cpp
static constexpr unsigned int api_version = 1150;   // 所需最低 WebView2 API 版本（版本号第 3 段）
static constexpr auto client_state_reg_sub_key = L"SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\";
static constexpr auto stable_release_guid      = L"{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
static constexpr auto default_release_channel_guid = stable_release_guid;
```

DLL 路径模板（`make_client_dll_path`，webview.h 第 3437 行起）：

```
<目录>\EBWebView\<arch>\EmbeddedBrowserWebView.dll
// arch ∈ { x64, x86, arm64 }，按编译目标选一个
```

查找入口 `find_available_client(browser_dir)`（第 3424 行起）：

1. `browserExecutableFolder` 非空 → `find_embedded_client`（Fixed Version 用法）：
   - DLL 路径 = `<browser_dir>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`；
   - 版本 = 读该 DLL 的版本资源 `GetFileVersionInfoSizeW / GetFileVersionInfoW / VerQueryValueW`，
     子块 `L"\\StringFileInfo\\040904B0\\ProductVersion"`（第 2842–2862 行）；
   - 校验 `parse_version(v)[2] >= 1150`，不满足则视为未找到；
   - `runtime_type = embedded`。
2. 否则先 `find_installed_client(api_version, /*system=*/true, guid)`（HKLM），失败再 `system=false`（HKCU）：
   - `RegOpenKeyExW(root, L"SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", 0, KEY_READ | KEY_WOW64_32KEY, &h)`
     —— **注意 `KEY_WOW64_32KEY`**：64 位进程实际落在 `HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{...}`；
   - `RegQueryValueExW` 读值名 **`EBWebView`**（REG_SZ，内容是“指向具体版本目录的完整路径”）；
   - 版本 = 该路径最后一段（`get_last_native_path_component`，按 `\` 切）；
   - 同样校验 `parse_version(v)[2] >= 1150`；
   - DLL 路径 = `<EBWebView 值>\EBWebView\<arch>\EmbeddedBrowserWebView.dll`；`runtime_type = installed`。

版本比较规则（webview 的全部逻辑就这么多）：

- `parse_version`：把 "a.b.c.d" 解析成最多 4 个 `unsigned` 分量，缺项/坏项补 0，多余丢弃（第 2808–2835 行）。
- 只做**下限门槛**：`分量[2] < 1150` → 拒绝（“运行时 API 版本低于所需”）。没有“多版本挑最新”的逻辑——
  HKLM 命中就不再看 HKCU；`EBWebView` 值本身由 EdgeUpdate 维护、直接指向当前安装版本目录。
- 官方（对照组）：微软文档规定的 Evergreen 检测键是 `Clients\{GUID}` 下 `pv (REG_SZ)`，
  要求 pv 存在且 > "0.0.0.0"（见 E 节引用）；本机实测该键同时带 `location = C:\Program Files (x86)\Microsoft\EdgeWebView\Application`。

**本机实测记录**（Windows x64，Runtime 156.0.4314.58）：

```
HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}
    EBWebView    REG_SZ    C:\Program Files (x86)\Microsoft\EdgeWebView\Application\156.0.4314.58
（HKCU 下无此键；纯 HKLM\SOFTWARE\Microsoft\... 的 64 位视图下亦无 —— 正因 KEY_WOW64_32KEY 才命中）

C:\Program Files (x86)\Microsoft\EdgeWebView\Application\156.0.4314.58\EBWebView\
    x64\EmbeddedBrowserWebView.dll   ← 存在
    x86\EmbeddedBrowserWebView.dll   ← 存在
```

（注册表还有官方 loader 用的键：`HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`
带 `name="Microsoft Edge WebView2 Runtime"`、`pv="156.0.4314.58"`、`location="C:\Program Files (x86)\Microsoft\EdgeWebView\Application"`。）

### D.2 加载机制与 Environment 创建（核心）

内建 loader 的加载动作（webview.h 第 3380 行起 `create_environment_with_options_impl`）：

1. `LoadLibraryW(路径)` —— **不带任何标志**（`native_library::load_library` 就是裸 `LoadLibraryW`，
   没有 `LOAD_WITH_ALTERED_SEARCH_PATH`/`LOAD_LIBRARY_SEARCH_*`；第 1149–1153 行）。
2. `GetProcAddress` 取导出名 **`CreateWebViewEnvironmentWithOptionsInternal`**，
   函数指针类型（第 3294–3298 行，逐字）：

   ```cpp
   using CreateWebViewEnvironmentWithOptionsInternal_t =
       HRESULT(STDMETHODCALLTYPE *)(
           bool, webview2_runtime_type, PCWSTR, IUnknown *,
           ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);
   // webview2_runtime_type { installed = 0, embedded = 1 }
   ```

3. 调用序列（逐字，第 3389–3393 行，仅去掉 `webview2_symbols::` 限定与换行）：

   ```cpp
   auto client_dll = native_library(found_client.dll_path.c_str());
   if (auto fn = client_dll.get(
           webview2_symbols::CreateWebViewEnvironmentWithOptionsInternal)) {
     return fn(true, found_client.runtime_type, user_data_dir, env_options,
               created_handler);
   }
   ```

   即 5 个参数：
   - arg0 `bool`：webview 恒传 `true`（该参数语义在 webview 源内无注释，未文档化）；
   - arg1 `webview2_runtime_type`（枚举 4 字节）：registry 安装版传 `installed(0)`，Fixed Version 传 `embedded(1)`；
   - arg2 `PCWSTR userDataFolder`：直接透传 loader API 的 userDataFolder（可为 null = 默认）；
   - arg3 `IUnknown *env_options`：即 `ICoreWebView2EnvironmentOptions*`（隐式转 IUnknown*），
     可为 null；webview 自己用 `WebView2EnvironmentOptions.h` 里的实现类填充；
   - arg4 `ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *created_handler`：环境创建完成回调。
   - **返回 HRESULT；成功后通过回调的 `Invoke(errorCode, ICoreWebView2Environment*)` 拿到 Environment 对象。**
     —— 这一步就是“不用官方 DLL 创建 Environment”的全部：拿到的就是标准 `ICoreWebView2Environment`
     COM 对象，之后按 B.1 的 vtable 正常 `CreateCoreWebView2Controller` 走下去。
4. 兜底分支：若 `CreateWebViewEnvironmentWithOptionsInternal` 不存在，取
   `GetProcAddress("DllCanUnloadNow")`；若 `DllCanUnloadNow() == 0`（S_OK，可卸载）则
   `client_dll.detach()`——把模块句柄置空、**故意不让析构函数调 FreeLibrary**，DLL 常驻进程。
   之后 `return ERROR_SUCCESS;`（兜底块在第 3395–3400 行）。

**运行时 DLL 导出实证**（`objdump -p`，本机 `EBWebView\x64\EmbeddedBrowserWebView.dll`，156.0.4314.58），
共 9 个导出：`CreateSharedWebViewEnvironmentInternal`、`CreateWebViewEnvironmentWithOptionsInternal`、
`DllCanUnloadNow`、`GetHandleVerifier`，以及 5 个 `telemetry_client::IDataFieldVisitor` 的 C++ 修饰名。
**没有 `GetEmbeddedBrowserWebViewData`**（老版本运行时如有历史导出也与 0.12.0 无关）。

### D.3 GetAvailableCoreWebView2BrowserVersionString / CreateCoreWebView2EnvironmentWithOptions 的 stub 逻辑

`loader` 类（webview.h 第 3325–3518 行）对外的两个入口按 `WEBVIEW_MSWEBVIEW2_EXPLICIT_LINK` 分派：

- 显式链接分支：`native_library m_lib{L"WebView2Loader.dll"}`（普通 `LoadLibraryW`，
  按标准 DLL 搜索顺序找 PATH/应用目录），命中则用其 `CreateCoreWebView2EnvironmentWithOptions`
  （`(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*) -> HRESULT`）
  与 `GetAvailableCoreWebView2BrowserVersionString`（`(PCWSTR, LPWSTR*) -> HRESULT`）。
- 未加载/未命中 → 走内建 impl：

  **stub `get_available_browser_version_string_impl(browser_dir, version)`**（第 3404 行起）：
  1. `version` 为空 → 返回 `-1`（HRESULT 意义上即 0xFFFFFFFF，非标准 HRESULT，仅作失败标记）；
  2. `find_available_client` 找不到 → 返回 `-1`；
  3. 找到 → `CoTaskMemAlloc(版本串字节数)` + `CopyMemory` 把 `std::wstring` 拷进去，
     `*version = 指针`，返回 `0`（S_OK）。—— 完全等价官方语义：版本串由调用方 `CoTaskMemFree`。
     注意 browser_dir 非空时返回的是 embedded 目录 DLL 的 ProductVersion。

  **stub `create_environment_with_options_impl(browser_dir, user_data_dir, env_options, created_handler)`**：
  1. `find_available_client`：browser_dir 非空 → embedded 查找；否则 HKLM → HKCU 查 ClientState；
     全部失败 → `return -1;`（0xFFFFFFFF）；
  2. `LoadLibraryW(<EBWebView 或 browser_dir>\EBWebView\<arch>\EmbeddedBrowserWebView.dll)`；
  3. `GetProcAddress("CreateWebViewEnvironmentWithOptionsInternal")` →
     `fn(true, runtime_type, user_data_dir, env_options, created_handler)` 并原样返回其 HRESULT；
  4. 导出缺失 → `DllCanUnloadNow()==0 则 detach`，返回 `ERROR_SUCCESS`。
     —— 对 `browserExecutableFolder=null` 的 Evergreen 路径，userDataFolder 原样透传（null = 系统默认
     `%LOCALAPPDATA%\{AppId}\EBWebView`，由运行时自行决定）。

注册表访问辅助（webview.h 第 2991–3040 行 `reg_key`）：
`RegOpenKeyExW(root, subkey, options, samDesired, &h)` 打开；`RegQueryValueExW(h, name, …)` 先取字节数再读数据；
`RegCloseKey` 关闭。Zig 里照抄这三个 API 即可。

### D.4 webview 引用的配套文件

- `compatibility/mingw/include/EventToken.h`：MinGW 无 SDK `eventtoken.h` 时的替代，全文核心一句：
  `typedef struct EventRegistrationToken { int64_t value; } EventRegistrationToken;`
  —— 8 字节、单 int64 字段，Zig: `extern struct { value: i64 }`。
- 其余（`WebView2.h`、`shlobj.h`、`shlwapi.h`、`version.lib`、advapi32 等）皆为系统/SDK 头。
  链接依赖：`#pragma comment(lib, "advapi32.lib ole32.lib shell32.lib shlwapi.lib user32.lib version.lib")`。
  Zig 侧对应：`advapi32`（注册表）、`ole32`（CoInitializeEx/CoTaskMemAlloc）、`version`（GetFileVersionInfoW）。

---

## E. 备选方案：官方 WebView2Loader.dll（NuGet 包内）

包内路径（NuGet `Microsoft.Web.WebView2` 1.0.4314.35，均已实测存在）：

```
build/native/x64/WebView2Loader.dll        (+ WebView2Loader.dll.lib 导入库 + WebView2LoaderStatic.lib 静态库)
build/native/x86/WebView2Loader.dll        (+ 同上两件)
build/native/arm64/WebView2Loader.dll
runtimes/win-x64/native/WebView2Loader.dll
runtimes/win-x86/native/WebView2Loader.dll
runtimes/win-arm64/native/WebView2Loader.dll
```

导出函数（`objdump -p build/native/x64/WebView2Loader.dll` 实测导出表，**7 个**，非老资料说的 3 个）：

```
Ordinal 1  CompareBrowserVersions
Ordinal 2  CreateCoreWebView2Environment
Ordinal 3  CreateCoreWebView2EnvironmentWithOptions
Ordinal 4  CreateOrJoinCoreWebView2ClusterEnvironment
Ordinal 5  GetAvailableCoreWebView2BrowserVersionString
Ordinal 6  GetAvailableCoreWebView2BrowserVersionStringWithOptions
Ordinal 7  GetCoreWebView2ClusterEnvironmentOptions
```

纯 Zig 加载器只需要前两个核心：`CreateCoreWebView2EnvironmentWithOptions` 与
`GetAvailableCoreWebView2BrowserVersionString`（签名见 C 节 STDAPI 声明）；
`CompareBrowserVersions` 可用于实现“多版本选最新”。

调用约定：STDAPI 展开为 `extern "C" HRESULT __stdcall`。x64 下 Windows 只有一种调用约定
（__stdcall 修饰被忽略，参数 RCX/RDX/R8/R9+栈）；x86 下是标准 stdcall（被调方清栈）。
若在 Zig 里 `LoadLibraryW("WebView2Loader.dll")` 后 GetProcAddress，`CallConvention.win64`/`Stdcall` 分别对应。

---

## F. 来源清单

| 内容 | 来源 | 版本/定位 |
|---|---|---|
| IID、vtable、枚举、STDAPI 声明、CALLBACK 用法 | NuGet `https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2` 解包 `build/native/include/WebView2.h`、`build/native/include/WebView2EnvironmentOptions.h`、`build/native/x64/WebView2Loader.dll` | **1.0.4314.35**（.nuspec `<version>` 字段） |
| 内建 loader 算法/导出名/调用序列 | `https://codeload.github.com/webview/webview/tar.gz/refs/tags/0.12.0` → `core/include/webview/webview.h`（第 3222–3520 行）、`compatibility/mingw/include/EventToken.h` | webview tag `0.12.0`（v 前缀的 tag 不存在，`v0.12.0` 返回 404，tag 名为 `0.12.0`） |
| Evergreen 官方检测键（pv） | `https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution`（“Detect if a WebView2 Runtime is already installed”，Approach 1） | 页面 git_commit 670ae635fa4287947d5ba1face1378dd9f7a4f4b |
| 本机实证 | reg query / objdump -p：ClientState+EBWebView 键值、Clients+pv 键值、`...\156.0.4314.58\EBWebView\x64\EmbeddedBrowserWebView.dll` 导出表 | Runtime 156.0.4314.58 |
| CALLBACK/WINAPI/STDAPI 宏定义原文 | zig 自带 mingw-w64 头 `D:/Scoop/apps/zig/current/lib/libc/include/any-windows-any/minwindef.h`（86–93、94–99 行）、`winnt.h`（472–473 行）、`basetyps.h`（19 行）—— 与 Windows SDK 同名头定义一致 | mingw-w64（zig 自带） |

### 手写 Zig 绑定的速查提醒

1. COM vtable = `[]*const fn (*self, ...) callconv(.w) HRESULT`（win64 用 `CallConvention.win64`，x86 用 `.Stdcall`）；
   每个接口对象首 8 字节（x64）是 vtable 指针，槽序严格按 B 节。
2. 枚举一律按 4 字节传参/存列；`BOOL=c_int`，不要用 Zig `bool`（1 字节）。
3. `EventRegistrationToken` = 8 字节 `i64` 值结构。
4. 所有 `[retval][out] LPWSTR*` / `CoTaskMemAlloc` 出来的字符串 → `CoTaskMemFree` 释放。
5. GUID 是 16 字节 struct，QueryInterface 的 `riid` 传 `*const GUID`，命中时 `*ppvObject = @ptrCast(self)` 并 AddRef。
6. 实现回调接口（Handler/EventHandler）时 QI 只需响应已知 IID + IUnknown，其余返回 `E_NOINTERFACE`（并置 `*ppvObject = null`）。

---

## G. Phase 0 实现实测补充（2026-11-07，绑定落地后追加）

1. **CompletedHandler 的 result 参数所有权**：`…EnvironmentCompletedHandler.Invoke` 与
   `…ControllerCompletedHandler.Invoke` 交付的 Environment/Controller 指针**不保证转移所有权**——
   不自行 AddRef 就长期持有，Invoke 结束后对象可能被释放（实测表现为 teardown 阶段读 vtable 段错误 0xffffffffffffffff）。
   正确姿势：Invoke 内 `AddRef` 后再存储，进程退出时 Release。事件 sink（`add_X` 的 handler）由 WebView2 自行引用计数，无需额外处理。
2. **ExecuteScript 的 resultObjectAsJson 不可 CoTaskMemFree**：实测对 `Invoke(errorCode, LPCWSTR result)` 的
   result 调用 CoTaskMemFree 会让宿主进程崩溃（它不是 CoTaskMemAlloc 分配的）；而
   `get_WebMessageAsJson` / `get_Uri` 等 `[retval][out] LPWSTR*` 出参**必须** CoTaskMemFree。两类字符串语义不同，绑定层需区分。
3. **纯 Zig loader 路线全链路验证通过**：`ClientState\{GUID}` → `EBWebView` 值 →
   `<dir>\EBWebView\x64\EmbeddedBrowserWebView.dll` →
   `CreateWebViewEnvironmentWithOptionsInternal(true, 0, userDataFolder, options, handler)`，
   本机（Evergreen 156.0.4314.58）可用，等价替代官方 WebView2Loader.dll。
4. **首次初始化耗时**：全新用户数据目录下首次 Environment 创建 + 首次导航 >6s（profile 建立），
   自动化测试的等待窗口要据此设置；之后复用同一目录则秒级完成。
5. `AddWebResourceRequestedFilter("https://zilt.app/*", ALL=0)` 直接可用（文档请求 200、favicon 404 均正确路由）。
6. **custom scheme 请求不携带 `Accept-Encoding`**（Phase C 实测，156.0.4314.58）：经
   `WebResourceRequested` 拦截的请求 `get_Headers` 读不到 Accept-Encoding，也从不回传
   If-None-Match——内容协商（gzip 下发）与 ETag/304 在此通道**均无从协商**。推论：custom
   scheme 响应不经过网络栈的内容解码器，`Content-Encoding: gzip` 的响应体会被当作已解码
   字节直接交给页面。
7. **custom scheme 响应附加头会破坏模块脚本**（Phase C 实测）：响应头串带第二个头
   （ETag 或 Content-Encoding，`
`/`
` 分隔皆然）时，`<script type="module">` 的
   MIME/头校验失败 → 模块静默不执行（无 console 可见、navigation 仍 SUCCESS）；经典
   `<script>` 容错不受影响。结论：custom scheme 200 响应**只发 Content-Type**；压缩资产
   须在宿主侧解压后以 identity 字节下发（Tauri brotli 同款，压缩收益落在 exe 体积）。
   另：多行头即使可用也应以 `
` 分隔（`CreateWebResourceResponse` 文档格式）。
