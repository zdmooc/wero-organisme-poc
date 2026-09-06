package org.mayabanque.wero.payment;

public enum PaymentStatus {
    CREATED,
    PROCESSING,
    PENDING,
    SETTLED,
    FAILED,
    UNKNOWN,
    RECOVERY_PENDING
}
