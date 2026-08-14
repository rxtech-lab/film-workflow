# MCP 服务器

Film Workflow 可以通过 HTTP **MCP** 端点对外暴露它的项目和生成能力，让你自己的工具——编辑器、命令行
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

服务器暴露的是应用自身的各项操作，工具集大致按标签页分组：

**项目与分组**

`list_projects`、`get_project`、`create_project`、`update_project`、`duplicate_project`、
`delete_project`、`move_project_to_group`、`list_project_groups`、`create_project_group`、
`update_project_group`、`delete_project_group`

**生成**

`music_generate`、`narrative_generate`、`image_generate`

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

## 注意事项

- 通过 MCP 请求的翻译一律使用 AI 后端。Apple 的设备端翻译引擎只能在应用内运行。
- **设置 › 智能体**中的字幕写入策略作用于应用自己的智能体线程；通过 MCP 连接的外部客户端是这些工具的
  另一个独立调用方。
- 绑定到所有网络接口会把服务暴露给你的局域网。请只在可信网络上这样做，并妥善保管 Bearer 令牌。
