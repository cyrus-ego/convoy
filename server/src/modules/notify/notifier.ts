import type { FastifyBaseLogger } from 'fastify';
import type { TripEvent } from '../realtime/protocol.js';

/** Các sự kiện đáng đẩy thông báo tới người đang để app chạy nền hoặc đã tắt app */
export const PUSH_EVENT_TYPES = new Set<TripEvent['type']>(['sos', 'lagging', 'stopped', 'signal_lost', 'trip_ended']);

export interface Notifier {
  notifyTripEvent(tripId: string, event: TripEvent, recipientIds: string[]): Promise<void>;
}

/** Tạm thời chỉ ghi log. Thay bằng FCM/APNs khi có thông tin Firebase project. */
export class LogNotifier implements Notifier {
  constructor(private readonly log: FastifyBaseLogger) {}

  async notifyTripEvent(tripId: string, event: TripEvent, recipientIds: string[]): Promise<void> {
    this.log.info({ tripId, eventType: event.type, uid: event.uid, recipients: recipientIds.length }, 'push (log only)');
  }
}
