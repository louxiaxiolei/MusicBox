# 音乐盒 MusicBox

原生 SwiftUI 写的 iOS 音乐播放器，本身不带任何曲库，所有内容来自用户导入的**音源插件**（JavaScript）。

## 功能

- 音源插件：从链接 / 粘贴 / 文件导入，支持 `srcUrl` 在线更新，多音源切换
- 插件接口与 MusicFree 基本一致：`search` / `getMediaSource` / `getLyric`
- 插件内可用 `axios`（常用子集）、`fetch`、`qs`、`crypto-js`（MD5/SHA/Base64）、`console`、`setTimeout`
- 播放：后台播放、锁屏 / 控制中心 / 耳机线控、拖动进度
- 列表循环 / 单曲循环 / 随机，播放队列（下一首播放、删除）
- LRC 歌词滚动，点歌词跳转
- 收藏、最近播放（本地保存）
- 内置一个 Internet Archive 示例音源（公有领域 / CC 音频），用来演示格式

## 拿到 IPA（不需要 Mac）

1. 在 GitHub 新建一个仓库（公开仓库可免费使用 macOS 构建机），把本项目全部文件推上去
2. 打开仓库的 **Actions** 页，工作流 *Build unsigned IPA* 会自动运行（也可以手动点 *Run workflow*）
3. 跑完后在这次运行的 **Artifacts** 里下载 `MusicBox-unsigned-ipa`，解压得到 `MusicBox-unsigned.ipa`
4. 用你的证书自签（爱思助手 / Sideloadly / ESign / `zsign` 都行），Bundle ID 可在签名时改

想要发 Release：打一个 `v1.0.0` 这样的 tag 推上去，IPA 会自动挂到 Release 上。

## 本地用 Xcode 构建（有 Mac 的话）

```bash
brew install xcodegen
xcodegen generate
open MusicBox.xcodeproj
```

## 写音源插件

见 `examples/example-archive.js`，App 内「音源 → 音源插件格式说明」里也有。最小结构：

```js
module.exports = {
  platform: '我的音源',
  version: '1.0.0',
  srcUrl: 'https://example.com/my.js',      // 可选，在线更新
  async search(keyword, page, type) {        // 返回 { isEnd, data: [...] }
    return { isEnd: true, data: [{ id, title, artist, album, artwork, duration }] };
  },
  async getMediaSource(musicItem, quality) { // 返回 { url, headers? } 或 url 字符串
    return { url: '...' };
  },
  async getLyric(musicItem) {                // 可选，返回 { rawLrc }
    return { rawLrc: '[00:00.00]...' };
  }
};
```

## 已知限制

- 依赖 `cheerio`、`dayjs`、`he` 或完整 `crypto-js`（AES/RSA）的插件暂时不能用
- 洛雪（LX）音源已支持：脚本按声明的平台展开（酷我/酷狗/QQ/网易云/咪咕），搜索走应用内置实现、取址走脚本；脚本依赖的后端服务若已停服，对应平台仍会取址失败
- 没有下载 / 离线缓存、歌单导入

## 声明

本项目只是一个播放器框架，不提供、不内置任何受版权保护的音乐内容。请只使用你有权访问的内容来源。
