export type Env = {
  DB: D1Database
  SYNC_TOKEN: string
}

export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message)
  }
}
