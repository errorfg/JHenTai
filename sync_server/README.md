# 同步服务（Cloudflare Worker + D1）

应用"云同步"中"同步服务（数据库）"一项所连接的服务端。与 S3/WebDAV 同步的区别：

- 数据按条保存在 D1 数据库中，每次同步只传输其他设备上次以来写入的记录；
- 删除（取消收藏、删除浏览历史等）会同步到其他设备；
- 同一条目在两台设备上都有修改时，以时间较晚的修改为准。

S3/WebDAV 同步不受影响，可以继续使用。所有设备应选择同一种同步方式。

## 部署

需要 Node.js 与一个 Cloudflare 账号。以下命令都在本目录执行。

1. 安装依赖：

   ```bash
   npm install
   ```

2. 登录 Cloudflare（会打开浏览器）：

   ```bash
   npx wrangler login
   ```

3. 创建 D1 数据库，记下输出中的 `database_id`：

   ```bash
   npx wrangler d1 create gallery-sync
   ```

4. 复制配置文件，并把 `database_id` 填进去（`wrangler.toml` 不会被提交）：

   ```bash
   cp wrangler.example.toml wrangler.toml
   ```

5. 设置令牌。令牌保存为 Worker 的加密变量，不写入任何文件；应用里填写的就是这个值。可以用 `openssl rand -hex 32` 生成：

   ```bash
   npx wrangler secret put SYNC_TOKEN
   ```

6. 部署，输出中的 `https://gallery-sync.<子域>.workers.dev` 就是服务地址：

   ```bash
   npx wrangler deploy
   ```

7. 在应用中打开"设置 → 高级 → 云同步设置"，打开"启用同步"，同步方式选择"同步服务（数据库）"，填入地址与令牌，点击"测试连接"。每台设备都要这样设置一次。

表结构由 Worker 在第一次请求时创建，不需要手动执行建表语句。

部分网络环境下 `workers.dev` 域名可能无法直接访问，可以在 Cloudflare 中为 Worker 绑定自己的域名，或在应用的网络设置中使用代理（同步请求遵循应用的代理设置）。

## 用量

D1 与 Workers 的免费额度足够个人使用。最大的一次用量发生在第一台设备首次同步时：每条记录写入一行（浏览历史、阅读进度、每个收藏各为一条）。之后每次同步只写入改动过的记录。

## 接口

协议 1，所有请求带 `Authorization: Bearer <令牌>`：

- `GET /v1/info`：`{"protocol": 1, "database": "<数据库编号>", "seq": <当前最大序号>}`
- `POST /v1/push`：请求体为记录数组，每条含 `kind`、`key`、`value`、`updatedAt`、`device`、`deleted`；同一 `(kind, key)` 以 `(updatedAt, device)` 较大者为准。
- `GET /v1/pull?since=<序号>&device=<设备>&limit=<条数>`：其他设备在该序号之后写入的记录，`{"records": [...], "next": <下次的序号>, "more": <是否还有>}`。

其他实现只要遵守同一协议，也可以作为同步服务使用。设计说明见 `docs/superpowers/specs/2026-10-11-record-sync-design.md`。

## 测试

```bash
npm test          # Worker 在本地 D1 上的测试
npm run check     # 类型检查
```

应用一侧的端到端测试 `test/record_sync_server_e2e_test.dart` 会在本机启动 `wrangler dev`，需要先在本目录执行过 `npm install`。
