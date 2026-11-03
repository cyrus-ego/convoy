export class AppError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export const badRequest = (code: string, message: string) => new AppError(400, code, message);
export const unauthorized = (message = 'Phiên đăng nhập không hợp lệ hoặc đã hết hạn') =>
  new AppError(401, 'unauthorized', message);
export const forbidden = (message = 'Bạn không có quyền làm việc này') => new AppError(403, 'forbidden', message);
/** Dùng cả khi không phải thành viên, để không lộ việc chuyến đi có tồn tại */
export const notFound = (message = 'Không tìm thấy') => new AppError(404, 'not_found', message);
export const conflict = (code: string, message: string) => new AppError(409, code, message);
