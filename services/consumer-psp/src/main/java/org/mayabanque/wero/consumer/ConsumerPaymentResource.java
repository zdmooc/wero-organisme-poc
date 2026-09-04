package org.mayabanque.wero.consumer;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.rest.client.inject.RestClient;

@Path("/consumer/payments")
@Consumes(MediaType.APPLICATION_JSON)
@Produces(MediaType.APPLICATION_JSON)
public class ConsumerPaymentResource {
    @RestClient WeroClient wero;

    @POST
    public PaymentResponse pay(PaymentRequest request) {
        return wero.forward(request);
    }

    public record PaymentRequest(String paymentId, long amountCents, String currency, String debtorAlias, String creditorAlias) {}
    public record PaymentResponse(String paymentId, String status, String settlementId) {}
}
