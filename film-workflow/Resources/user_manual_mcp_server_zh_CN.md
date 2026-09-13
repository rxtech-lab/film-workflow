# MCP 服务器

Film Workflow 可以通过 HTTP **MCP** 端点对外暴露当前打开的影片——它的素材库、生成器和序列——让你自己的工具——编辑器、命令行
智能体、脚本——直接驱动这个应用。

**Claude Code** 和 **Codex** 这两个智能体引擎也正是通过它与应用通信的。

下面的所有设置都位于**设置 › MCP 服务器**。

## 开启

**启用 MCP 服务器**会启动服务。一旦启用，之后每次应用启动都会自动开启。

## 网络

- **绑定**——**仅本机（127.0.0.1）**或**所有网络接口（0.0.0.0）**。仅本机是默认值，也更安全：只有本机上
  的软件能连接。
- **基础端口**——默认 7711。如果该端口被占用，会依次尝试到 base+9 之间第一个空闲端口。**状态**部分始终
  显示实际使用的端口，并会说明它与基础端口不一致的情况。

## 状态

一个彩色圆点和一行状态文字表明服务是否在运行，完整 URL 会连同复制按钮一起显示。出错时会在这里以红色
显示，而不会悄无声息地失败。

## Bearer 令牌

第一次启用服务时会为你生成一个令牌。

- **显示** / **隐藏**用于查看默认被遮蔽的令牌。
- 复制按钮把它放到剪贴板。
- **重新生成令牌**会签发新的令牌。已用旧令牌连接的客户端将无法继续工作。

绑定到所有网络接口时**必须**提供令牌；本机请求会跳过校验。请在每个请求上带上这个头：

```
Authorization: Bearer <令牌>
```

令牌保存在系统钥匙串中，而不是设置文件里。

## 从 Claude Code 连接

服务运行时，设置面板会显示一条已经填好你实际 URL 和令牌的现成命令。复制后执行即可：

```
claude mcp add --transport http film http://127.0.0.1:7711/...
```

绑定到所有网络接口时，同一条命令会附带 `Authorization` 头。

## 工具覆盖范围

服务器暴露的是应用自身的各项操作，用的也是编辑器里的说法：**影片**是当前打开的文档，**素材库**里放着
分在**文件夹**中的**素材项**，每次生成都会保留为一个**版本**，**序列**则是由这些版本剪成的时间线。每个
工具都接受可选的 `film` 参数（来自 `film_list` 的 id、路径或名称），未指定时作用于当前活动窗口。

**影片**

`film_list`

**素材库与文件夹**

`footage_list`、`footage_get`、`footage_create`、`footage_update`、`footage_duplicate`、
`footage_move`、`footage_import`、`footage_delete`、`folder_list`、`folder_create`、
`folder_rename`、`folder_delete`

素材项通过 `footage_id` 定位；种类为 `music`、`narration`、`caption`、`image`、`video`、`remotion`、
`sequence` 和 `imported`。`footage_list` 的每一行都带有 `sourceId`——最新的版本——可直接交给
`sequence_add_clip` 放到轨道上。

**生成**

`music_generate`、`narration_generate`、`image_generate`、`video_generate`、`video_job_status`、
`video_resume`

**字幕**

`caption_create`、`caption_transcribe`、`caption_list_segments`、`caption_search_segments`、
`caption_update_segment`、`caption_set_speakers`、`caption_propose_edits`、`caption_translate`、
`caption_versions`、`caption_export`

**播客**

`podcast_create`、`podcast_add_content`、`podcast_update_content`、`podcast_remove_content`、
`podcast_list_speakers`、`podcast_update_settings`

**Remotion**

`remotion_list_files`、`remotion_read_file`、`remotion_write_file`、`remotion_edit_file`、
`remotion_add_image`、`remotion_remove_image`、`remotion_add_audio`、`remotion_remove_audio`、
`remotion_generate_image`、`remotion_take_screenshot`、`remotion_take_screenshots`

**序列**

`sequence_create`、`sequence_list`、`sequence_get`、`sequence_set_timeline`、`sequence_add_clip`、
`sequence_remove_clip`、`sequence_render`、`sequence_renders`

`sequence_render` 按 `captions` 参数处理时间线上的字幕片段：`burn_in`（烧录进画面）、`embedded`
（每种语言一条内嵌字幕轨）、`sidecar`（每种语言一个 `.srt` 或 `.vtt` 文件，放在影片旁，格式由
`caption_sidecar_format` 决定）或 `none`。`caption_languages` 是 BCP-47 语言代码列表，`""` 表示原文；
烧录时取第一项作为显示语言，`caption_bilingual` 会在其上方加上原文。结果中包含 `captions` 与
`caption_files`。

## 注意事项

- 通过 MCP 请求的翻译一律使用 AI 后端。Apple 的设备端翻译引擎只能在应用内运行。
- **设置 › 智能体**中的字幕写入策略作用于应用自己的智能体线程；通过 MCP 连接的外部客户端是这些工具的
  另一个独立调用方。
- 绑定到所有网络接口会把服务暴露给你的局域网。请只在可信网络上这样做，并妥善保管 Bearer 令牌。
