package org.mayabanque.wero.mock;

import jakarta.inject.Inject;
import jakarta.ws.rs.*;
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
        var settlement = sctInst.transfer(new TransferRequest(request.paymentId(), request.amountCents(), request.currency()));
        return new PaymentResponse(request.paymentId(), "SETTLED", settlement.settlementId());
    }

    public record PaymentRequest(String paymentId, long amountCents, String currency, String debtorAlias, String creditorAlias) {}
    public record PaymentResponse(String paymentId, String status, String settlementId) {}
    public record TransferRequest(String paymentId, long amountCents, String currency) {}
    public record TransferResponse(String settlementId, String status) {}
}
