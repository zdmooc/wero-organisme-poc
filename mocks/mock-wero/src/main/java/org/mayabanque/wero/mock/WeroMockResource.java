package org.mayabanque.wero.mock;

import jakarta.inject.Inject;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RestClient;

@Path("/wero/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class WeroMockResource {
    @Inject
    @RestClient
    SctInstClient sctInst;

    @POST
    public PaymentResponse pay(PaymentRequest request) {
        var settlement = sctInst.transfer(new TransferRequest(
                request.paymentId(),
                request.amountCents(),
                request.currency(),
                request.simulateMode()));
        return new PaymentResponse(request.paymentId(), settlement.status(), settlement.settlementId());
    }

    public record PaymentRequest(
            String paymentId,
            long amountCents,
            String currency,
            String debtorAlias,
            String creditorAlias,
            String simulateMode) {}

    public record PaymentResponse(String paymentId, String status, String settlementId) {}
    public record TransferRequest(String paymentId, long amountCents, String currency, String simulateMode) {}
    public record TransferResponse(String settlementId, String status) {}
}
